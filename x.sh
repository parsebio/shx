#!/usr/bin/env bash
# =============================================================================
# Batch/OOM diagnostic toolbox (bash 3.2 OK; runs on stock macOS bash)
# -----------------------------------------------------------------------------
# Script entry point:
#   ./x.sh <command> [args...]
#
# Public commands are registered in one place at the bottom of this file:
#   _xsh_main
#
# Source-compatible function names remain available:
#   open_task_shell, scan_oom_processes, scan_stall_processes,
#   diagnose_run (umbrella; diagnose_stall_run / diagnose_oom_run pin one probe)
#
# No code is duplicated: the Batch->ECS->EC2 trace lives once in
# _aws_batch_job_to_ec2 (used by both open_task_shell and the diagnoser). The
# probes (scan_stall_processes / scan_oom_processes) are procps-free and shipped
# via `declare -f`, then docker-exec'd INSIDE each task's own container over SSM
# so the scan sees only that task's PID namespace.
#
# Required environment:
#   API_ACCESS_TOKEN   Personal access token (Authorization: Bearer ...).
#   WORKSPACE_ID       Numeric workspace ID.
#   API_ENDPOINT       API base URL.
#   PROC_PATTERN       Default remote process pattern for diagnosis.
#
# Requirements: awscli v2 configured for the target account/region; the SSM
# Session Manager plugin (for open_task_shell); jq, curl, awk.
# =============================================================================

# =============================================================================
# Shared AWS helper -- the single Batch->ECS->EC2 trace
# =============================================================================

# Trace a Batch job ID to its underlying EC2 instance ID. Quiet: prints the EC2
# instance id on stdout, or returns 1 if any hop cannot be resolved.
#   $1 = Batch job id
#   $2 = (optional) queue->cluster TSV cache file to skip repeat lookups
_aws_batch_job_to_ec2() {
	local job_id="$1" qcache="${2:-}"
	local ci_arn q ce cluster ec2

	ci_arn="$(aws batch describe-jobs --jobs "$job_id" \
		--query 'jobs[0].container.containerInstanceArn' --output text 2>/dev/null </dev/null)"
	[ -z "$ci_arn" ] || [ "$ci_arn" = "None" ] && return 1

	q="$(aws batch describe-jobs --jobs "$job_id" \
		--query 'jobs[0].jobQueue' --output text 2>/dev/null </dev/null)"
	[ -z "$q" ] || [ "$q" = "None" ] && return 1

	# Reuse a cached queue->cluster mapping when a cache file is provided.
	cluster=""
	[ -n "$qcache" ] && cluster="$(awk -F'\t' -v k="$q" '$1==k{print $2; exit}' "$qcache" 2>/dev/null)"
	if [ -z "$cluster" ]; then
		ce="$(aws batch describe-job-queues --job-queues "$q" \
			--query 'jobQueues[0].computeEnvironmentOrder[0].computeEnvironment' \
			--output text 2>/dev/null </dev/null)"
		[ -z "$ce" ] || [ "$ce" = "None" ] && return 1
		cluster="$(aws batch describe-compute-environments --compute-environments "$ce" \
			--query 'computeEnvironments[0].ecsClusterArn' --output text 2>/dev/null </dev/null)"
		[ -z "$cluster" ] || [ "$cluster" = "None" ] && return 1
		[ -n "$qcache" ] && printf '%s\t%s\n' "$q" "$cluster" >>"$qcache"
	fi

	ec2="$(aws ecs describe-container-instances --cluster "$cluster" \
		--container-instances "$ci_arn" \
		--query 'containerInstances[0].ec2InstanceId' --output text 2>/dev/null </dev/null)"
	[ -z "$ec2" ] || [ "$ec2" = "None" ] && return 1
	printf '%s\n' "$ec2"
}

# Ship an arbitrary shell script to an instance via SSM, wait for it to finish,
# and print its StandardOutputContent on stdout. Returns 0 only if the SSM
# invocation reported Success. This is the single send-poll-collect path reused
# by every remote command (scan_oom_processes, show_star_progress, ...).
#   $1 = EC2 instance id
#   $2 = shell script text (typically `declare -f` of a function plus a call)
#   $3 = (optional) human-readable comment for the SSM command
_xsh_ssm_run() {
	local instance="$1" script="$2" comment="${3:-x.sh remote command}"
	# NB: avoid the name `status` -- it is a read-only special variable in zsh
	# (an alias for $?), and assigning to it aborts the function mid-poll.
	local params cmd_id inv_status out tries=0 errf

	# SSM caps --comment at 100 characters; over that, send-command rejects the
	# whole call. Keep callers from tripping it regardless of what they pass.
	comment="${comment:0:100}"

	params="$(jq -n --arg c "$script" '{commands: [$c]}')"
	errf="$(mktemp)"
	cmd_id="$(aws ssm send-command --instance-ids "$instance" \
		--document-name AWS-RunShellScript \
		--comment "$comment" \
		--parameters "$params" \
		--query 'Command.CommandId' --output text 2>"$errf" </dev/null)"
	if [ -z "$cmd_id" ] || [ "$cmd_id" = "None" ]; then
		printf '(SSM send failed on %s)\n' "$instance"
		sed 's/^/    aws: /' "$errf" >&2
		rm -f "$errf"
		return 1
	fi
	rm -f "$errf"

	while [ "$tries" -lt 100 ]; do
		tries=$((tries + 1))
		inv_status="$(aws ssm get-command-invocation --command-id "$cmd_id" \
			--instance-id "$instance" --query 'Status' --output text 2>/dev/null </dev/null)"
		case "$inv_status" in
		Success | Failed | Cancelled | TimedOut) break ;;
		*) sleep 3 ;;
		esac
	done
	out="$(aws ssm get-command-invocation --command-id "$cmd_id" \
		--instance-id "$instance" --query 'StandardOutputContent' --output text 2>/dev/null </dev/null)"
	printf '%s\n' "$out"
	# Surface the remote script's stderr too -- otherwise failures inside the
	# command (e.g. "FASTQ not found") vanish and the caller just sees output
	# stop with no explanation.
	local err
	err="$(aws ssm get-command-invocation --command-id "$cmd_id" \
		--instance-id "$instance" --query 'StandardErrorContent' --output text 2>/dev/null </dev/null)"
	if [ -n "$err" ] && [ "$err" != "None" ]; then
		printf '%s\n' "$err" >&2
	fi
	[ "$inv_status" = "Success" ]
}

# =============================================================================
# Public: open an SSM session on the instance backing a Batch job
# =============================================================================
open_task_shell() {
	local usage
	read -r -d '' usage <<'EOF' || true
Usage: open_task_shell [-h|--help] <job_id>

Trace a task's Native ID to its underlying EC2 instance and open
an SSM Session Manager session on it.

Arguments:
  job_id        Batch job ID (AWS Batch executor)
                e.g. aa00a1e2-1e96-4cbb-a670-3b33c5ac356d

Options:
  -h, --help    Show this help message and exit.

Requirements:
  - awscli (v2) configured with credentials for the target account/region.
  - The Session Manager plugin for the AWS CLI.
  - IAM permissions for batch:DescribeJobs,
    batch:DescribeComputeEnvironments, ecs:DescribeContainerInstances,
    and ssm:StartSession.

Example:
  open_task_shell aa00a1e2-1e96-4cbb-a670-3b33c5ac356d
EOF

	# --- Parse arguments ------------------------------------------------------
	local job_id=""
	while [ $# -gt 0 ]; do
		case "$1" in
		-h | --help)
			printf '%s\n' "$usage"
			return 0
			;;
		-*)
			printf 'Error: unknown option %s\n\n' "$1" >&2
			printf '%s\n' "$usage" >&2
			return 1
			;;
		*)
			if [ -n "$job_id" ]; then
				printf 'Error: too many arguments.\n\n' >&2
				printf '%s\n' "$usage" >&2
				return 1
			fi
			job_id="$1"
			;;
		esac
		shift
	done

	if [ -z "$job_id" ]; then
		printf 'Error: missing required argument <job_id>.\n\n' >&2
		printf '%s\n' "$usage" >&2
		return 1
	fi

	# --- Trace + connect (trace logic shared via _aws_batch_job_to_ec2) -------
	printf '==> Tracing Batch job %s to its EC2 instance...\n' "$job_id"
	local ec2_instance_id
	ec2_instance_id="$(_aws_batch_job_to_ec2 "$job_id")" || {
		printf 'Error: could not trace Batch job %s to an EC2 instance.\n' "$job_id" >&2
		return 1
	}
	printf '    EC2 instance: %s\n' "$ec2_instance_id"

	printf '==> Starting SSM session on %s\n' "$ec2_instance_id"
	aws ssm start-session --target "$ec2_instance_id"
}

# =============================================================================
# Shared: read OOM / memory evidence for a pid's cgroup (cause attribution)
# -----------------------------------------------------------------------------
# The single source of truth for "did this cgroup get OOM-killed, and what are
# its memory limits". Used both by scan_oom_processes (its whole purpose) and by
# scan_stall_processes (to attribute a stall to OOM). Shipped alongside whichever
# probe needs it via `declare -f`, so it must stay self-contained.
#
# Emits one TSV line: cgroup <TAB> oom_kill <TAB> oom_group <TAB> mem_max <TAB>
# mem_current <TAB> events   (events is last; it is the only field with spaces).
# Tunable (env): CGROUP_ROOT (default /sys/fs/cgroup). cgroup v2 only.
#   $1 = pid
# =============================================================================
_oom_evidence() {
	local pid="$1" root="${CGROUP_ROOT:-/sys/fs/cgroup}"
	local cg base oom_group mem_max mem_cur events oom_kill
	# cgroup v2: the unified hierarchy line starts with "0::"
	cg=$(awk -F: '/^0::/{print $3}' "/proc/$pid/cgroup" 2>/dev/null)
	base="${root}${cg}"
	oom_group=$(cat "$base/memory.oom.group" 2>/dev/null)
	mem_max=$(cat "$base/memory.max" 2>/dev/null)
	mem_cur=$(cat "$base/memory.current" 2>/dev/null)
	events=$(cat "$base/memory.events" 2>/dev/null | tr '\n' ' ')
	oom_kill=$(printf '%s' "$events" | awk '{for(i=1;i<NF;i++) if($i=="oom_kill") print $(i+1)}')
	printf '%s\t%s\t%s\t%s\t%s\t%s\n' \
		"${cg:-}" "${oom_kill:-0}" "${oom_group:-<n/a>}" \
		"${mem_max:-<n/a>}" "${mem_cur:-<n/a>}" "${events:-<n/a>}"
}

# =============================================================================
# Shared: procps-free process discovery (works INSIDE a task container)
# -----------------------------------------------------------------------------
# The probes are docker-exec'd into the task's own container so they see only
# that task's PID namespace. Task containers are minimal and frequently lack
# procps (pgrep/ps) -- the STAR driver (_sp_star_running) hits the same wall and
# walks /proc with `find` for exactly this reason. These two helpers are the
# pgrep replacements; everything else the probes need (cat, tr, awk, sort) is
# coreutils and present. Shipped alongside the probes via `declare -f`.
#
# _proc_pids               -> every live pid, one per line (the enumerator)
# _proc_cmd PID            -> the process's cmdline (NUL args joined with spaces)
# _proc_state PID          -> state letter from /proc/PID/stat (R,S,D,Z,...)
# _proc_pids_matching PAT  -> pids whose cmdline contains substring PAT (pgrep -f)
# _proc_children PPID      -> direct child pids of PPID (pgrep -P)
# _proc_userspace          -> "pid<TAB>cmdline" for every process with a cmdline
#                             (i.e. real userspace procs, not kernel threads)
# =============================================================================

# Enumerate pids without procps. Match pid dirs by NAME glob ('[0-9]*'), NOT by
# `-regex`: GNU find's default -regex is emacs-flavoured ('+' = one-or-more) but
# busybox/BSD find treat '+' literally, so a -regex enumeration silently returns
# nothing there -- which would make every pattern look absent. `-name` glob
# matching behaves the same across GNU/BSD/busybox.
_proc_pids() {
	[ -d /proc ] || return 0
	find /proc -maxdepth 1 -type d -name '[0-9]*' 2>/dev/null | while IFS= read -r d; do
		printf '%s\n' "${d#/proc/}"
	done
}

# cmdline with NUL args joined by spaces. 2>/dev/null comes BEFORE the input
# redirect so that if the pid vanished (a transient process reaped between
# enumeration and read), the shell's "No such file" message is suppressed too,
# not just tr's stderr.
_proc_cmd() { tr '\0' ' ' 2>/dev/null <"/proc/$1/cmdline"; }

# state letter from /proc/PID/stat (R,S,D,Z,...); empty if the pid is gone.
_proc_state() {
	local raw rest
	raw=$(cat "/proc/$1/stat" 2>/dev/null) || return 0
	rest=${raw##*") "}
	set -- $rest
	printf '%s' "${1:-}"
}

_proc_pids_matching() {
	local pat="$1" pid cmd
	while IFS= read -r pid; do
		[ -n "$pid" ] || continue
		cmd=$(_proc_cmd "$pid")
		case "$cmd" in *"$pat"*) printf '%s\n' "$pid" ;; esac
	done <<EOF
$(_proc_pids)
EOF
}

_proc_children() {
	local ppid="$1" pid raw rest
	while IFS= read -r pid; do
		[ -n "$pid" ] || continue
		raw=$(cat "/proc/$pid/stat" 2>/dev/null) || continue
		[ -z "$raw" ] && continue
		# stat: "pid (comm) state ppid ...". comm may hold spaces/parens, so
		# split AFTER the final ") " -- then $1=state, $2=ppid.
		rest=${raw##*") "}
		set -- $rest
		[ "${2:-}" = "$ppid" ] && printf '%s\n' "$pid"
	done <<EOF
$(_proc_pids)
EOF
}

_proc_userspace() {
	local pid cmd
	while IFS= read -r pid; do
		[ -n "$pid" ] || continue
		cmd=$(_proc_cmd "$pid")
		# kernel threads have an empty cmdline -- skip them, list real processes.
		[ -n "${cmd// /}" ] && printf '%s\t%s\n' "$pid" "$cmd"
	done <<EOF
$(_proc_pids)
EOF
}

# =============================================================================
# Shared: suggest a pattern when the requested one matched nothing
# -----------------------------------------------------------------------------
# Called from a probe's no-match branch. The user asked for a pattern with no
# live process; the most useful next thing is to show what IS running so they
# can re-target. If 'split-pipe' processes exist, distil them to their
# `--mode <X>` (the canonical pattern axis). Otherwise -- the case where the
# task is between split-pipe sub-phases (e.g. shelling out to cp/STAR) --
# say so; and only when asked (show_all=1) dump every userspace process, since
# the full Nextflow/fusion plumbing list is noise by default.
#   $1 = show_all (1 to list all container processes on no split-pipe match)
# Shipped via `declare -f`; stays self-contained.
# =============================================================================
_suggest_split_pipe_patterns() {
	local show_all="${1:-0}" running modes p
	running=$(for p in $(_proc_pids_matching 'split-pipe'); do _proc_cmd "$p"; echo; done)
	running=$(printf '%s\n' "$running" | sed '/^[[:space:]]*$/d')
	if [ -n "$running" ]; then
		echo "  But 'split-pipe' IS running here. Currently running mode(s):"
		modes=$(printf '%s\n' "$running" | grep -oE -- '--mode[[:space:]]+[^[:space:]]+' \
			| awk '{print $2}' | sort -u)
		if [ -n "$modes" ]; then
			local m
			printf '%s\n' "$modes" | while IFS= read -r m; do
				[ -z "$m" ] && continue
				printf "    - 'split-pipe --mode %s'\n" "$m"
			done
			echo "  Re-run with  -p/--pattern 'split-pipe --mode <mode>'  to target one of these."
		else
			printf '%s\n' "$running" | sort -u | sed 's/^/    - /'
			echo "  Re-run with  -p/--pattern '<command substring>'  to target one of these."
		fi
		return 0
	fi

	# No 'split-pipe' in any cmdline. Keep it terse by default; the full process
	# table is mostly Nextflow/fusion plumbing, so dump it only on --all.
	echo "  No 'split-pipe' command line is running in this container right now"
	echo "  (the task may be between split-pipe sub-phases, e.g. copying output)."
	if [ "$show_all" = 1 ]; then
		local all
		all=$(_proc_userspace)
		if [ -n "$all" ]; then
			echo "  All userspace processes in THIS container:"
			printf '%s\n' "$all" | sed 's/^/    [pid /; s/\t/] /' | cut -c1-160
			echo "  Re-run with  -p/--pattern '<substring of a command line above>'  to target one."
		else
			echo "  (no userspace processes visible / /proc not readable here)."
		fi
	else
		local n
		n=$(_proc_userspace | grep -c .)
		echo "  ${n} other userspace process(es) are running; re-run with -a/--all to list them,"
		echo "  or pass -p/--pattern '<substring>' to target a specific one."
	fi
}

# =============================================================================
# Public: OOM-stuck process finder (run on a host, or docker-exec'd in a container)
# -----------------------------------------------------------------------------
# Find processes that are hung because the kernel OOM-killed some of their
# children but NOT the process itself, leaving the parent deadlocked. It walks
# EVERY process matching a pattern, prints its cgroup + memory facts, and flags
# the ones that are stuck (OOM-killed children + zombie/defunct children).
# Process discovery is procps-free (raw /proc via the _proc_* helpers), so it
# works inside minimal task containers that lack pgrep/ps -- which is how
# diagnose_run ships it: docker-exec'd into the task's own container, scoped to
# that task's PID namespace rather than the whole host.
#
# Usage:
#   scan_oom_processes [--all|-a] [--match|-m TAG] [-p|--pattern PATTERN] [PATTERN]
#   PATTERN is matched as a substring of each process's cmdline (or set PROC_PATTERN).
#
# Tunables (env): CGROUP_ROOT (default /sys/fs/cgroup), PROC_PATTERN.
# =============================================================================
scan_oom_processes() {

	# Default: show only STUCK matches. --all/-a shows every one.
	# --match/-m TAG restricts to matches whose cmdline contains TAG.
	local show_all=0
	local cmd_match=""
	local proc_pattern="${PROC_PATTERN:-}"
	while [ $# -gt 0 ]; do
		case "$1" in
		-a | --all)
			show_all=1
			shift
			;;
		-m | --match)
			if [ -z "${2:-}" ]; then
				echo "Error: $1 requires a TAG argument." >&2
				return 2
			fi
			cmd_match="$2"
			shift 2
			;;
		--match=*)
			cmd_match="${1#*=}"
			shift
			;;
		-p | --pattern)
			if [ -z "${2:-}" ]; then
				echo "Error: $1 requires a PATTERN argument." >&2
				return 2
			fi
			proc_pattern="$2"
			shift 2
			;;
		--pattern=*)
			proc_pattern="${1#*=}"
			shift
			;;
		-h | --help)
			echo "Usage: scan_oom_processes [--all|-a] [--match|-m TAG] [-p|--pattern PATTERN] [PATTERN]"
			echo "  PATTERN          cmdline substring of the process(es) to inspect"
			echo "                   (positional or via -p/--pattern)"
			echo "  (default)        print only STUCK matches"
			echo "  --all            print every match regardless of verdict"
			echo "  --match TAG      only consider matches whose cmdline contains TAG"
			return 0
			;;
		--)
			shift
			proc_pattern="${1:-$proc_pattern}"
			break
			;;
		-*)
			echo "Unknown option: $1 (use --all, -m TAG, -p PATTERN, or -h)" >&2
			return 2
			;;
		*)
			proc_pattern="$1"
			shift
			;;
		esac
	done

	if [ -z "$proc_pattern" ]; then
		echo "Error: no process PATTERN given (pass one as an argument or set PROC_PATTERN)." >&2
		echo "Try: scan_oom_processes --help" >&2
		return 2
	fi

	local stuck_pids=()
	local pids pid cg oom_group mem_max mem_cur mem_events zombies oom_kill ev
	local block is_stuck cmdline matched=0

	pids=$(_proc_pids_matching "$proc_pattern")

	if [ -z "$pids" ]; then
		echo ">>> NO-MATCH: no process matches the pattern: $proc_pattern"
		echo "  If you expected one, confirm you are in the right container and that"
		echo "  the process is still running."
		_suggest_split_pipe_patterns "$show_all"
		return 0
	fi

	for pid in $pids; do
		# Full command line tells us which instance/task this is.
		cmdline=$(_proc_cmd "$pid")

		# --match: skip matches whose cmdline doesn't contain TAG.
		if [ -n "$cmd_match" ] && [[ "$cmdline" != *"$cmd_match"* ]]; then
			continue
		fi
		matched=1

		# cgroup OOM / memory facts (shared with scan_stall_processes).
		ev=$(_oom_evidence "$pid")
		IFS=$'\t' read -r cg oom_kill oom_group mem_max mem_cur mem_events <<<"$ev"
		oom_kill=${oom_kill:-0}

		# Count zombie/defunct direct children the parent can never reap
		# (procps-free: walk the parent's children and read each one's state).
		local _c
		zombies=0
		for _c in $(_proc_children "$pid"); do
			[ "$(_proc_state "$_c")" = "Z" ] && zombies=$((zombies + 1))
		done

		# Build the per-process report block (so we can choose whether to print it).
		is_stuck=0
		block="=== pid=$pid  cgroup=${cg:-<unknown>} ==="$'\n'
		block+="  cmdline          : ${cmdline}"$'\n'
		block+="  memory.oom.group : ${oom_group:-<n/a>}"$'\n'
		block+="  memory.max       : ${mem_max:-<n/a>}"$'\n'
		block+="  memory.current   : ${mem_cur:-<n/a>}"$'\n'
		block+="  memory.events    : ${mem_events:-<n/a>}"$'\n'
		block+="  zombie children  : $zombies"$'\n'

		if [ "${oom_kill:-0}" -gt 0 ] 2>/dev/null && [ "${zombies:-0}" -gt 0 ] 2>/dev/null; then
			is_stuck=1
			stuck_pids+=("$pid")
			block+="  >>> VERDICT      : STUCK — oom_kill=$oom_kill and $zombies zombie child(ren)."$'\n'
			block+="  >>>                The command line above identifies which instance this is."$'\n'
		elif [ "${oom_kill:-0}" -gt 0 ] 2>/dev/null; then
			block+="  >>> VERDICT      : OOM occurred (oom_kill=$oom_kill) but no zombies seen right now."$'\n'
		else
			block+="  >>> VERDICT      : healthy (no oom_kill recorded)."$'\n'
		fi

		# Print this block if it's stuck, or if --all was requested.
		if [ "$is_stuck" -eq 1 ] || [ "$show_all" -eq 1 ]; then
			printf '%s\n' "$block"
		fi
	done

	# Nothing survived the --match filter.
	if [ -n "$cmd_match" ] && [ "$matched" -eq 0 ]; then
		echo "No process found whose cmdline contains '$cmd_match'."
		echo "Re-run without --match (or with --all) to list every match on this host."
		return 0
	fi

	echo "-----------------------------------------------------------------------------"
	if [ "${#stuck_pids[@]}" -gt 0 ]; then
		echo "STUCK pid(s): ${stuck_pids[*]}"
		echo "Capture the memory.events line (oom_kill > 0, oom_group_kill 0) and the"
		echo "cmdline as evidence before killing the process."
	else
		echo "No stuck process identified (no cgroup with both oom_kill>0 and zombies)."
		[ "$show_all" -eq 0 ] && echo "Re-run with --all to see every match and its memory facts."
	fi
}

# =============================================================================
# Public: detect a STALLED split-pipe PRE job, and attribute the cause (on host)
# -----------------------------------------------------------------------------
# This is the SYMPTOM-first probe: it answers "is this job making forward
# progress?" regardless of why it stopped, then -- when it is NOT -- tries to
# name the cause (OOM today, via the shared _oom_evidence). That is the natural
# debugging order: notice the stall, then ask why. scan_oom_processes is the
# cause-first counterpart (it only fires when it finds OOM evidence); this one
# has no such blind spot -- a stall from a segfault or a deadlock is flagged
# just the same, and simply reported as "not OOM".
#
# The companion long sampler (pre_progress_check.sh) needs a 30-60 min window to
# tell PINNED from GLACIAL throughput. That window is NOT needed to answer "is it
# stalled?": that follows from near-instantaneous signals plus a short churn
# sample, so this finishes in under a minute and is safe to ship over SSM.
#
#   * dispatcher kernel wait-channel (/proc/<pid>/wchan) -> parked in wait()/join?
#   * worker process state (/proc/<pid>/stat)            -> zombie? running? D-wait?
#   * a short double-sample                              -> is the pool CHURNING
#                                                           (workers reaped/spawned)?
#   * cgroup memory.events (via _oom_evidence)           -> was the cause OOM?
#
# Verdicts:
#   WORKING       live worker(s) reading / in D / running / burning CPU -> fine.
#   CRASH-LOOP?   pool churns but no worker did ANY I/O -> between-batch gap OR a
#                 crash-restart loop; disambiguate by output growth (FLAGGED).
#   HUNG          zombies unreaped while the dispatcher is parked in a wait/pipe
#                 channel and does no I/O -> wedged; will not recover (FLAGGED).
#   DEGRADED      some (not all) workers zombie -> heading toward a hang (FLAGGED).
#   IDLE/STALLED  nothing reading/writing/zombie/churning -> between phases; recheck.
#
# Each FLAGGED verdict carries a cause line: OOM (with the oom_kill count and
# memory limits) when the cgroup shows it, otherwise a pointer to dmesg/logs.
# Process discovery is procps-free (raw /proc via the _proc_* helpers) so it runs
# inside minimal task containers; diagnose_run docker-exec's it into the task's
# own container. Lines starting ">>> FLAG" mark a task needing attention.
#
# Usage: scan_stall_processes [--window SECONDS] [-p|--pattern PATTERN] [--all] [PATTERN]
#   PATTERN defaults to 'split-pipe --mode pre'; --window defaults to 20s.
# =============================================================================
scan_stall_processes() {
	local window=20 show_all=0 pattern=""
	while [ $# -gt 0 ]; do
		case "$1" in
		-w | --window)
			[ -n "${2:-}" ] || {
				echo "scan_stall_processes: --window needs a value" >&2
				return 2
			}
			window="$2"
			shift 2
			;;
		--window=*)
			window="${1#*=}"
			shift
			;;
		-p | --pattern)
			[ -n "${2:-}" ] || {
				echo "scan_stall_processes: --pattern needs a value" >&2
				return 2
			}
			pattern="$2"
			shift 2
			;;
		--pattern=*)
			pattern="${1#*=}"
			shift
			;;
		-a | --all)
			show_all=1
			shift
			;;
		-h | --help)
			echo "Usage: scan_stall_processes [--window SECONDS] [-p|--pattern PATTERN] [--all] [PATTERN]"
			echo "  Fast STALL detector + cause attribution (default window 20s,"
			echo "  default pattern 'split-pipe --mode pre'). The pattern may be given"
			echo "  positionally or via -p/--pattern."
			return 0
			;;
		-*)
			echo "scan_stall_processes: unknown option $1" >&2
			return 2
			;;
		*)
			pattern="$1"
			shift
			;;
		esac
	done
	[ -n "$pattern" ] || pattern="split-pipe --mode pre"
	case "$window" in
	'' | *[!0-9]*)
		echo "scan_stall_processes: --window must be an integer" >&2
		return 2
		;;
	esac

	# recursive descendant walker (a dispatcher's children are its workers)
	_ssp_desc() {
		local r=$1 k
		for k in $(_proc_children "$r"); do
			echo "$k"
			_ssp_desc "$k"
		done
	}

	# one process row: "pid<TAB>role<TAB>state<TAB>cpu_ticks<TAB>rchar<TAB>wchan".
	# Emits nothing if the pid is gone (fully reaped) -- absence is the signal.
	_ssp_row() {
		local p=$1 role=$2 raw rest state cpu rchar wch
		raw=$(cat "/proc/$p/stat" 2>/dev/null) || return 0
		[ -z "$raw" ] && return 0
		rest=${raw#*") "} # strip "pid (comm) "
		set -- $rest      # $1=state ... $12=utime $13=stime
		state=$1
		cpu=$((${12:-0} + ${13:-0}))
		rchar=$(awk '/^rchar/{print $2; exit}' "/proc/$p/io" 2>/dev/null)
		rchar=${rchar:-0}
		wch=$(cat "/proc/$p/wchan" 2>/dev/null)
		wch=${wch:-0}
		printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$p" "$role" "$state" "$cpu" "$rchar" "$wch"
	}

	# one snapshot of the whole tree. Re-discovers dispatchers AND workers each
	# call, so a respawned dispatcher PID or freshly spawned worker is captured.
	_ssp_snap() {
		local disp d c cmd
		disp=$(_proc_pids_matching "$pattern")
		[ -z "$disp" ] && return 0
		for d in $disp; do _ssp_row "$d" dispatcher; done
		for d in $disp; do
			for c in $(_ssp_desc "$d"); do
				case " $disp " in *" $c "*) continue ;; esac # nested dispatcher: skip
				cmd=$(_proc_cmd "$c")
				case "$cmd" in *mem_loop*) continue ;; esac # memory profiler, not a worker
				_ssp_row "$c" worker
			done
		done
	}

	local disp_list
	disp_list=$(_proc_pids_matching "$pattern" | tr '\n' ' ')
	disp_list=${disp_list% }
	if [ -z "$disp_list" ]; then
		echo ">>> NO-MATCH: no process matches the pattern: $pattern"
		_suggest_split_pipe_patterns "$show_all"
		return 0
	fi

	# Name the modes actually matched, so even a benign verdict tells the caller
	# WHICH split-pipe is running (a broad pattern can match a non-PRE stage).
	local d disp_modes
	disp_modes=$(for d in $disp_list; do
		_proc_cmd "$d"
		echo
	done | grep -oE -- '--mode[[:space:]]+[^[:space:]]+' | awk '{print $2}' | sort -u | tr '\n' ' ')
	disp_modes=${disp_modes% }

	# A broad pattern (e.g. plain 'split-pipe') can match several modes at once --
	# typically unrelated tasks co-located on the same host. Lumping them yields a
	# muddy verdict, so warn and tell the caller to pin a single mode.
	local n_modes
	n_modes=$(printf '%s' "$disp_modes" | tr ' ' '\n' | grep -c .)
	if [ "${n_modes:-0}" -gt 1 ]; then
		echo ">>> NOTE: pattern '$pattern' matched MULTIPLE modes: $disp_modes"
		echo "  These are likely separate tasks sharing this host; the verdict below"
		echo "  mixes them. Pin one mode for a clean read, e.g.:"
		printf '%s' "$disp_modes" | tr ' ' '\n' | while IFS= read -r m; do
			[ -z "$m" ] && continue
			echo "    scan_stall_processes -p 'split-pipe --mode $m'"
		done
	fi

	local f1 f2
	f1=$(mktemp)
	f2=$(mktemp)
	_ssp_snap >"$f1"
	echo "Dispatcher(s): $disp_list   |   modes: ${disp_modes:-<none>}   |   sampling ${window}s for churn ..."
	sleep "$window"
	_ssp_snap >"$f2"

	# Cause attribution: read the dispatcher cgroup's OOM evidence (workers share
	# it). The verdict is the symptom; this names WHY when it can. Take the max
	# oom_kill across dispatchers, with that cgroup's memory limits.
	local oomkill=0 oommax="<n/a>" oomcur="<n/a>" d ev k om oc
	for d in $disp_list; do
		ev=$(_oom_evidence "$d")
		k=$(printf '%s' "$ev" | cut -f2)
		om=$(printf '%s' "$ev" | cut -f4)
		oc=$(printf '%s' "$ev" | cut -f5)
		if [ "${k:-0}" -gt "${oomkill:-0}" ] 2>/dev/null; then
			oomkill=$k
			oommax=$om
			oomcur=$oc
		fi
	done

	awk -F'\t' -v SHOWALL="$show_all" -v DISPLIST="$disp_list" \
		-v OOMKILL="$oomkill" -v OOMMAX="$oommax" -v OOMCUR="$oomcur" '
	FNR==NR { role1[$1]=$2; s1[$1]=$3; c1[$1]=$4; rc1[$1]=$5; w1[$1]=$6; in1[$1]=1; next }
	{ role2[$1]=$2; s2[$1]=$3; c2[$1]=$4; rc2[$1]=$5; w2[$1]=$6; in2[$1]=1 }
	END {
		printf "\n%-9s %-10s %-6s %12s %12s  %s\n", "PID","ROLE","STATE","dcpu_ticks","drchar","WCHAN"
		for (p in in2) allp[p]=1
		for (p in in1) allp[p]=1
		for (pass=0; pass<2; pass++) {
			for (p in allp) {
				role=(p in in2)?role2[p]:role1[p]
				if (pass==0 && role!="dispatcher") continue
				if (pass==1 && role=="dispatcher") continue
				st=(p in in2)?s2[p]:"GONE"
				dc=((p in in1)&&(p in in2))?(c2[p]-c1[p]):0
				dr=((p in in1)&&(p in in2))?(rc2[p]-rc1[p]):0
				wc=(p in in2)?w2[p]:w1[p]
				printf "%-9s %-10s %-6s %12s %12s  %s\n", p, role, st, dc, dr, wc
			}
		}
		nlive=0; zomb=0; pzomb=0; dwait=0; running=0; worksig=0; reaped=0; appeared=0
		for (p in in2) {
			if (role2[p]!="worker") continue
			nlive++
			if (s2[p]=="Z") zomb++
			if (s2[p]=="D") { dwait++; worksig=1 }
			if (s2[p]=="R") { running++; worksig=1 }
			if ((p in in1) && s1[p]=="Z" && s2[p]=="Z") pzomb++
			if ((p in in1) && (c2[p]+0)>(c1[p]+0)) worksig=1
			if ((p in in1) && (rc2[p]+0)>(rc1[p]+0)) worksig=1
			if (!(p in in1)) appeared++
		}
		for (p in in1) { if (role1[p]=="worker" && !(p in in2)) reaped++ }
		churn=(reaped>0 || appeared>0)?1:0
		dbusy=0; dwaitall=1
		for (p in in2) {
			if (role2[p]!="dispatcher") continue
			if ((p in in1) && ((c2[p]+0)>(c1[p]+0) || (rc2[p]+0)>(rc1[p]+0))) dbusy=1
			# blocked waiting on IPC: classic wedge channels (do_wait, pipe_read, ...)
			if (w2[p] !~ /wait|pipe_read/) dwaitall=0
		}
		# cause line, printed under every FLAGGED verdict
		if (OOMKILL+0 > 0)
			cause = sprintf("  Likely cause: OOM -- cgroup memory.events oom_kill=%s (memory.max=%s, memory.current=%s).\n  -> fix: raise the PRE-stage memory or shrink chunk size, not just restart.", OOMKILL, OOMMAX, OOMCUR)
		else
			cause = "  Cause: not OOM (oom_kill=0). Check `dmesg` for a segfault and the task log for a\n  Python traceback -- the worker(s) died some other way."

		printf "\nworkers: %d live (%d zombie, %d persistent-zombie, %d running, %d disk-wait) | reaped %d, spawned %d | dispatcher busy=%d wait=%d | oom_kill=%s\n", \
			nlive, zomb, pzomb, running, dwait, reaped, appeared, dbusy, dwaitall, OOMKILL

		print  "================================ VERDICT ================================"
		if (worksig==1) {
			print "WORKING: live worker(s) reading / in disk-wait / running / burning CPU."
			print "  Not hung. (For throughput + ETA, use the long on-host sampler.)"
		} else if (churn==1) {
			printf ">>> FLAG: CRASH-LOOP? pool is churning (reaped %d, spawned %d) but NO worker\n", reaped, appeared
			print  "  showed any I/O or CPU this window. Either a brief between-batch gap OR a"
			print  "  crash-restart loop spinning with no progress. Disambiguate by output growth"
			print  "  and whether the SAME zombie PIDs persist while a dispatcher PID changes."
			print  cause
		} else if (pzomb>0 && dbusy==0 && dwaitall==1) {
			printf ">>> FLAG: HUNG. %d zombie worker(s) unreaped across the window while every\n", pzomb
			print  "  dispatcher is parked in a wait/pipe channel and does no I/O -- wedged"
			print  "  (e.g. blocked in wait()/join or reading a result pipe from dead workers)."
			printf "  This will NOT recover; kill the dispatcher(s) [%s] and re-run.\n", DISPLIST
			print  cause
		} else if (zomb>0 && zomb==nlive && dbusy==0) {
			printf ">>> FLAG: HUNG. all %d live worker(s) are zombie and the pool is not recycling\n", nlive
			printf "  (no reap/spawn). Dispatcher likely wedged; kill [%s] and re-run.\n", DISPLIST
			print  cause
		} else if (zomb>0) {
			printf ">>> FLAG: DEGRADED. %d/%d worker(s) zombie -- some died; watch for a hang.\n", zomb, nlive
			print  cause
		} else if (dbusy==1) {
			print "ACTIVE (parent-side): dispatcher is busy but workers idle -- a single-threaded"
			print "  parent phase; workers wait. Not hung."
		} else {
			print "IDLE/STALLED: no I/O, no zombies, no churn. Possibly between phases -- recheck."
		}
		print  "========================================================================="
	}' "$f1" "$f2"

	rm -f "$f1" "$f2"
	unset -f _ssp_desc _ssp_row _ssp_snap 2>/dev/null
}

# =============================================================================
# diagnose_run internals (namespaced _dor_)
# =============================================================================

# --- private: fail-fast preflight (env + required commands) ------------------
_dor_preflight() {
	local missing="" cmd
	[ -z "${API_ACCESS_TOKEN:-}" ] && missing="$missing API_ACCESS_TOKEN"
	[ -z "${WORKSPACE_ID:-}" ] && missing="$missing WORKSPACE_ID"
	[ -z "${API_ENDPOINT:-}" ] && missing="$missing API_ENDPOINT"
	if [ -n "$missing" ]; then
		printf 'diagnose_oom_run: missing required environment variable(s):%s\n' "$missing" >&2
		return 1
	fi
	for cmd in "$@"; do
		command -v "$cmd" >/dev/null 2>&1 || {
			printf 'diagnose_oom_run: required command not found: %s\n' "$cmd" >&2
			return 1
		}
	done
}

# --- private: usage ----------------------------------------------------------
_dor_usage() {
	cat >&2 <<'EOF'
Usage:
  diagnose_run --run-id <id> [diagnose-args...]       Resolve run -> workflow, diagnose RUNNING tasks
  diagnose_run --workflow-id <id> [diagnose-args...]  Diagnose a workflow's RUNNING tasks
  diagnose_run list <workflow-id>                     Print "<nativeId>\t<label>\t<workdir>\t<container>" rows
  diagnose_run tasks [diagnose-args...] [id...]       Diagnose tasks from stdin/args (the back half)

Each task is probed INSIDE its own container (docker exec, its own PID namespace),
so co-located tasks on the same instance never pollute one another's result. Bare
native IDs (the 'tasks' subcommand with no workdir/container) fall back to a
host-wide scan and are labelled as such.

diagnose-args forwarded to the task diagnoser:
  -c, --check oom|stall|all    probe(s) to run (default stall):
                                 stall -> scan_stall_processes (no progress; HUNG /
                                          crash-loop / degraded, with OOM cause attribution)
                                 oom   -> scan_oom_processes   (proactive OOM scan:
                                          child OOM -> stuck parent)
  -p, --pattern PATTERN        process pattern (oom needs this or PROC_PATTERN;
                                 stall defaults to 'split-pipe --mode pre')
  -s, --step STEP              only tasks whose Nextflow step matches STEP
                                 (case-insensitive substring)
  -a, --all                    print every match, not just flagged ones

Aliases: diagnose_stall_run pins --check stall; diagnose_oom_run pins --check oom.

Required environment: API_ACCESS_TOKEN, WORKSPACE_ID, API_ENDPOINT
EOF
}

# --- API: resolve a run name/ID to a workflow ID -----------------------------
# Bare ID on stdout; resolution details and errors on stderr (safe to capture).
_dor_resolve_workflow_id() {
	[ $# -lt 1 ] && {
		printf 'diagnose_oom_run: --run-id requires a value\n' >&2
		return 2
	}
	_dor_preflight curl jq awk || return 1

	local run="$1"
	local auth=(-H "Authorization: Bearer $API_ACCESS_TOKEN")
	local ep="${API_ENDPOINT%/}"

	local rows
	rows="$(curl -fsSL --get "${auth[@]}" \
		--data-urlencode "search=$run" \
		--data-urlencode "max=50" \
		--data-urlencode "workspaceId=$WORKSPACE_ID" \
		"$ep/workflow")" || {
		printf 'diagnose_oom_run: API request failed while searching for run %s\n' "$run" >&2
		return 1
	}

	rows="$(jq -r '.workflows[].workflow | "\(.id)\t\(.runName)\t\(.status)"' <<<"$rows")"
	if [ -z "$rows" ]; then
		printf 'diagnose_oom_run: no workflow found matching run %s\n' "$run" >&2
		return 1
	fi

	# Prefer an exact runName match; otherwise fall back to the search results.
	local exact chosen count
	exact="$(awk -F'\t' -v r="$run" '$2==r' <<<"$rows")"
	[ -n "$exact" ] && chosen="$exact" || chosen="$rows"

	count="$(printf '%s\n' "$chosen" | grep -c .)"
	if [ "$count" -gt 1 ]; then
		printf 'diagnose_oom_run: run %s is ambiguous (%s matches):\n' "$run" "$count" >&2
		printf '%s\n' "$chosen" | awk -F'\t' '
			BEGIN {
				headers[1] = "Workflow ID"
				headers[2] = "Workflow Name"
				headers[3] = "Status"
				for (i = 1; i <= 3; i++) widths[i] = length(headers[i])
			}
			{
				rows[NR, 1] = $1
				rows[NR, 2] = $2
				rows[NR, 3] = $3
				for (i = 1; i <= 3; i++) {
					if (length(rows[NR, i]) > widths[i]) widths[i] = length(rows[NR, i])
				}
			}
			END {
				printf "%-*s  %-*s  %-*s\n", widths[1], headers[1], widths[2], headers[2], widths[3], headers[3]
				for (i = 1; i <= 3; i++) {
					printf "%s%s", sep, repeat("-", widths[i])
					sep = "  "
				}
				printf "\n"
				for (row = 1; row <= NR; row++) {
					printf "%-*s  %-*s  %-*s\n", widths[1], rows[row, 1], widths[2], rows[row, 2], widths[3], rows[row, 3]
				}
			}
			function repeat(value, count, result) {
				result = ""
				while (count-- > 0) result = result value
				return result
			}
		' >&2
		printf '\nBecause this output is ambiguous, rerun with --workflow-id <workflow-id> using one of the IDs above.\n' >&2
		printf 'In ambiguous cases, --workflow-id is required instead of --run-id.\n' >&2
		return 2
	fi

	printf 'Resolved run %s -> %s\n' "$run" "$chosen" >&2 # human-readable
	cut -f1 <<<"$chosen"                                  # bare ID to stdout
}

# --- API: list a workflow's RUNNING tasks ------------------------------------
# Emits one TSV row per RUNNING task: "<nativeId>\t<label>\t<workdir>\t<container>"
# where label is "sample=<tag> step=<process>". The workdir + container image
# let the diagnoser exec the probe inside each task's OWN container (its own PID
# namespace), instead of a host-wide scan that lumps co-located tasks together.
_dor_list_running_tasks() {
	if [ $# -lt 1 ] || [ "$1" = "-h" ] || [ "$1" = "--help" ]; then
		printf 'Usage: diagnose_oom_run list <workflow-id>\n' >&2
		return 2
	fi
	_dor_preflight curl jq || return 1

	local wf="$1"
	local auth=(-H "Authorization: Bearer $API_ACCESS_TOKEN")
	local ep="${API_ENDPOINT%/}"
	local offset=0 total page

	while :; do
		page="$(curl -fsSL --get "${auth[@]}" \
			--data-urlencode "max=100" \
			--data-urlencode "offset=$offset" \
			--data-urlencode "workspaceId=$WORKSPACE_ID" \
			"$ep/workflow/$wf/tasks")" || {
			printf 'diagnose_oom_run: API request failed at offset %s for workflow %s\n' "$offset" "$wf" >&2
			return 1
		}

		total="$(jq -r '.total // 0' <<<"$page")"

		jq -r '.tasks[] | (.task // .)
		         | select(.status=="RUNNING")
		         | [ (.nativeId | tostring),
		             ("sample=\(.tag) step=\(.process)"),
		             (.workdir // ""),
		             (.container // "") ] | @tsv' <<<"$page"

		offset=$((offset + 100))
		[ "$offset" -ge "$total" ] && break
	done
}

# --- shared: the set of functions a probe needs shipped with it --------------
# Both probes plus the procps-free /proc toolkit and the cgroup/suggestion
# helpers. Listed once so the host-wide and in-container runners can't drift.
_dor_probe_func_src() {
	case "$1" in
	stall) declare -f scan_stall_processes ;;
	oom | *) declare -f scan_oom_processes ;;
	esac
	declare -f _oom_evidence _suggest_split_pipe_patterns \
		_proc_pids _proc_cmd _proc_state _proc_pids_matching _proc_children _proc_userspace
}

# --- diagnostic: run one PROBE host-wide on one instance via SSM -------------
# FALLBACK path, used only when a task's container can't be resolved (no
# workdir/container from the API). Ships the probe to the host and scans every
# matching process there -- which, on a host packing several task containers,
# lumps unrelated tasks together. Prefer _dor_run_in_container.
#   $1 = EC2 instance id   $2 = process pattern   $3 = extra flags (e.g. --all)
#   $4 = probe name: oom (scan_oom_processes) | stall (scan_stall_processes)
_dor_run_remote() {
	local instance="$1" pattern="$2" extra="$3" probe="${4:-oom}"
	local func_src remote_script call comment

	case "$probe" in
	stall)
		# The stall probe has its own sensible default pattern (the PRE
		# dispatcher), so an empty pattern is fine here.
		[ -n "$pattern" ] || pattern='split-pipe --mode pre'
		call="scan_stall_processes ${extra} $(printf '%q' "$pattern")"
		comment="scan_stall_processes $pattern"
		;;
	oom | *)
		call="scan_oom_processes ${extra} $(printf '%q' "$pattern")"
		comment="scan_oom_processes $pattern"
		;;
	esac
	func_src="$(_dor_probe_func_src "$probe")" || return 1

	remote_script="set -u
${func_src}
${call}"

	_xsh_ssm_run "$instance" "$remote_script" "$comment"
}

# --- diagnostic: run one PROBE INSIDE a task's container via SSM -------------
# The task-scoped path (mirrors _sp_run_remote). Finds THIS task's container on
# the host -- by the work dir embedded in its immutable launch config, falling
# back to the image tag -- then docker-exec's the procps-free probe inside it,
# so the probe sees only this task's PID namespace. No cross-task pollution.
#   $1 = EC2 instance id   $2 = container image ref   $3 = s3:// work directory
#   $4 = process pattern   $5 = extra flags (e.g. --all)   $6 = probe: oom|stall
_dor_run_in_container() {
	local instance="$1" image="$2" workdir="$3" pattern="$4" extra="$5" probe="${6:-stall}"
	local tag="${image##*:}"
	local fusion="/fusion/s3/${workdir#s3://}"
	local func_src call comment inner_script b64 host_script

	case "$probe" in
	stall)
		[ -n "$pattern" ] || pattern='split-pipe --mode pre'
		call="scan_stall_processes ${extra} $(printf '%q' "$pattern")"
		comment="stall(in-container) $tag"
		;;
	oom | *)
		call="scan_oom_processes ${extra} $(printf '%q' "$pattern")"
		comment="oom(in-container) $tag"
		;;
	esac
	func_src="$(_dor_probe_func_src "$probe")" || return 1

	# inner script runs INSIDE the container; base64 so it survives the
	# docker-exec stdin pipe without quoting hazards (same trick as _sp_run_remote).
	inner_script="set -u
${func_src}
${call}"
	b64="$(printf '%s' "$inner_script" | base64 | tr -d '\n')"

	# outer script runs on the HOST: locate the task's container, then pipe the
	# decoded inner script into it. Every remote-evaluated $ is escaped (\$).
	host_script="set -u
image=$(printf '%q' "$image")
tag=$(printf '%q' "$tag")
fusion=$(printf '%q' "$fusion")
b64=$(printf '%q' "$b64")

cid=\"\"
for c in \$(sudo docker ps --no-trunc --format '{{.ID}}'); do
	if sudo docker inspect \"\$c\" 2>/dev/null | grep -qF -- \"\$fusion\"; then
		cid=\$c
		break
	fi
done
if [ -z \"\$cid\" ]; then
	cid=\$(sudo docker ps --no-trunc | grep -F -- \"\$tag\" | awk '{print \$1}' | head -1)
	[ -n \"\$cid\" ] && echo \"WARN: no container config referenced \$fusion; falling back to first \$tag container (\$cid). It may belong to a different task.\" >&2
fi
if [ -z \"\$cid\" ]; then
	# stdout (not stderr) so the orchestrator captures + detects this sentinel.
	echo \">>> NO-CONTAINER: no running container for image \$image (searched by work dir and tag \$tag).\"
	exit 1
fi
echo \"Container id    : \$cid\"
printf '%s' \"\$b64\" | base64 -d | sudo docker exec -i \"\$cid\" bash -s"

	_xsh_ssm_run "$instance" "$host_script" "$comment"
}

# --- diagnostic: diagnose a set of tasks -------------------------------------
# Reads "<nativeId>\t<label>\t<workdir>\t<container>" rows on stdin (or bare
# native IDs as args), resolves each task to its EC2 instance, and runs the
# selected probe(s) per task INSIDE that task's own container (docker exec) --
# falling back to a host-wide scan only when no workdir/container is known. The
# default probe is the symptom-first stall check; callers (diagnose_oom_run)
# override it to oom by exporting _DOR_DEFAULT_CHECK -- a variable rather than a
# positional arg, so the list/tasks subcommands keep working.
_dor_diagnose_tasks() {
	local pattern="${PROC_PATTERN:-}" show_all="" probes="${_DOR_DEFAULT_CHECK:-stall}"
	local step_filter=""
	local -a native_ids=()

	while [ $# -gt 0 ]; do
		case "$1" in
		-p | --pattern)
			if [ -z "${2:-}" ]; then
				printf 'Error: %s requires a PATTERN argument.\n' "$1" >&2
				return 2
			fi
			pattern="$2"
			shift 2
			;;
		-s | --step | --process)
			if [ -z "${2:-}" ]; then
				printf 'Error: %s requires a STEP argument.\n' "$1" >&2
				return 2
			fi
			step_filter="$2"
			shift 2
			;;
		--step=* | --process=*)
			step_filter="${1#*=}"
			shift
			;;
		-c | --check)
			case "${2:-}" in
			oom | stall) probes="$2" ;;
			all) probes="oom stall" ;;
			*)
				printf 'Error: --check must be oom, stall, or all.\n' >&2
				return 2
				;;
			esac
			shift 2
			;;
		--check=*)
			case "${1#*=}" in
			oom | stall) probes="${1#*=}" ;;
			all) probes="oom stall" ;;
			*)
				printf 'Error: --check must be oom, stall, or all.\n' >&2
				return 2
				;;
			esac
			shift
			;;
		-a | --all)
			show_all="--all"
			shift
			;;
		-h | --help)
			printf 'Usage: diagnose_run tasks [-p PATTERN] [-c oom|stall|all] [-s STEP] [--all] [nativeId...]\n'
			printf '  Reads "<nativeId>\\t<label>\\t<workdir>\\t<container>" TSV rows on stdin if\n'
			printf '  no IDs are given (the shape diagnose_run list emits). Rows carrying a\n'
			printf '  workdir+container are probed INSIDE that container; bare native IDs (and\n'
			printf '  legacy id-only lines) fall back to a host-wide scan.\n'
			printf '  -c/--check selects the probe(s) (default stall). The oom probe needs a\n'
			printf '  PATTERN (-p/--pattern or PROC_PATTERN); the stall probe defaults to\n'
			printf "  'split-pipe --mode pre'.\n"
			printf '  -s/--step STEP keeps only tasks whose Nextflow step matches STEP\n'
			printf '  (case-insensitive substring).\n'
			return 0
			;;
		-*)
			printf 'Unknown option: %s\n' "$1" >&2
			return 2
			;;
		*)
			native_ids+=("$1")
			shift
			;;
		esac
	done

	# The oom probe needs an explicit pattern; the stall probe supplies its own
	# default, so a missing pattern is only fatal when oom is among the probes.
	if [ -z "$pattern" ]; then
		case " $probes " in
		*" oom "*)
			printf 'Error: the oom probe needs a PATTERN (pass -p/--pattern or set PROC_PATTERN).\n' >&2
			return 2
			;;
		esac
	fi

	local t
	for t in aws jq awk base64; do
		command -v "$t" >/dev/null 2>&1 || {
			printf 'Error: %s not found.\n' "$t" >&2
			return 1
		}
	done
	local pr
	for pr in $probes; do
		case "$pr" in
		oom) declare -F scan_oom_processes >/dev/null 2>&1 || {
			printf 'Error: scan_oom_processes not defined.\n' >&2
			return 1
		} ;;
		stall) declare -F scan_stall_processes >/dev/null 2>&1 || {
			printf 'Error: scan_stall_processes not defined.\n' >&2
			return 1
		} ;;
		esac
	done

	# --- announce what we are about to do ------------------------------------
	# The user should know up front: which probe (mode), which process pattern
	# it greps for, that each task is probed INSIDE its own container, and --
	# for the stall probe -- that each task is sampled for a churn window, so a
	# stall scan is not instant. The effective stall pattern is the default when
	# none was given (mirrors scan_stall_processes).
	local _dor_stall_window=20 mode_desc disp_pattern
	case "$probes" in
	stall) mode_desc="stall (symptom-first: HUNG / crash-loop / degraded; no progress/ETA)" ;;
	oom) mode_desc="oom (OOM-killed children left a deadlocked parent)" ;;
	*) mode_desc="all (oom + stall)" ;;
	esac
	disp_pattern="$pattern"
	if [ -z "$disp_pattern" ]; then
		disp_pattern="split-pipe --mode pre  (stall default)"
	fi
	printf '==> Mode (--check): %s\n' "$mode_desc" >&2
	printf '==> Process pattern (--pattern): %s\n' "$disp_pattern" >&2
	[ -n "$step_filter" ] && printf '==> Step filter (--step): %s\n' "$step_filter" >&2
	printf '==> Each task is probed INSIDE its own container (its own PID namespace),\n' >&2
	printf '    so co-located tasks no longer pollute the result.\n' >&2
	case " $probes " in
	*" stall "*)
		printf '==> The stall probe samples each task for ~%ss of churn, sequentially.\n' \
			"$_dor_stall_window" >&2
		printf '    Expect roughly ~%ss per task of waiting (plus SSM + docker-exec overhead).\n' \
			"$_dor_stall_window" >&2
		;;
	esac

	# temp files: normalised input lines, queue->cluster cache, resolved worklist
	local intasks qcache worklist
	intasks="$(mktemp)"
	qcache="$(mktemp)"
	worklist="$(mktemp)"
	# Clean up temp files when this function returns. bash uses the RETURN
	# pseudo-signal; zsh has no RETURN trap, but an EXIT trap set inside a
	# function is function-local there and fires on return -- so pick per shell.
	if [ -n "${ZSH_VERSION:-}" ]; then
		trap 'rm -f "$intasks" "$qcache" "$worklist"' EXIT
	else
		trap 'rm -f "$intasks" "$qcache" "$worklist"' RETURN
	fi

	# gather input -> "<nid>\t<label>\t<workdir>\t<container>" lines.
	#   - args: bare native IDs (no workdir/container -> host-wide fallback).
	#   - stdin: TSV from _dor_list_running_tasks (4 fields), or a legacy
	#     "<id> <label>" line (workdir/container empty -> host-wide fallback).
	if [ ${#native_ids[@]} -gt 0 ]; then
		local id
		for id in "${native_ids[@]}"; do printf '%s\t%s\t\t\n' "$id" "$id" >>"$intasks"; done
	else
		if [ -t 0 ]; then
			printf 'Error: no native IDs given (pass as args or pipe them in).\n' >&2
			return 1
		fi
		# Tab-aware: field1=id, field2=label, field3=workdir, field4=container.
		# A line with no tab is a legacy "id [label...]" form (whitespace-split):
		# first token = id, the remainder = label, no workdir/container.
		awk -F'\t' '{
			if (NF >= 2) { print $1 "\t" $2 "\t" $3 "\t" $4 }
			else {
				id=$0;  sub(/[[:space:]].*/, "", id)
				lbl=$0; sub(/^[^[:space:]]+[[:space:]]*/, "", lbl)
				if (lbl=="") lbl=id
				print id "\t" lbl "\t\t"
			}
		}' >"$intasks"
	fi

	local n_in
	n_in="$(grep -c . "$intasks")"
	[ "$n_in" -eq 0 ] && {
		printf 'No native IDs to process.\n' >&2
		return 1
	}

	# --- optional: keep only tasks whose Nextflow step matches --step ---------
	# The step lives in the label as "step=<process>". Match is case-insensitive
	# substring, so --step <name> selects any step whose process name contains
	# <name>. On no match, list the steps that ARE running so it can be corrected.
	if [ -n "$step_filter" ]; then
		local kept
		kept="$(mktemp)"
		awk -F'\t' -v want="$step_filter" '
			BEGIN { w = tolower(want) }
			{
				step = $2
				sub(/^.*step=/, "", step)   # "" if the label has no step= field
				if (index(tolower(step), w) > 0) print
			}' "$intasks" >"$kept"
		local n_kept
		n_kept="$(grep -c . "$kept")"
		if [ "$n_kept" -eq 0 ]; then
			printf "Error: --step '%s' matched none of the %s running task(s).\n" "$step_filter" "$n_in" >&2
			printf 'Steps currently running in this workflow:\n' >&2
			awk -F'\t' '{ s=$2; sub(/^.*step=/, "", s); if (s=="") s="(no step)"; print s }' "$intasks" \
				| sort | uniq -c | sort -rn | sed 's/^/    /' >&2
			return 1
		fi
		cat "$kept" >"$intasks"
		rm -f "$kept"
		printf "==> Step filter (--step '%s'): %s of %s task(s) match.\n" "$step_filter" "$n_kept" "$n_in" >&2
		n_in="$n_kept"
	fi

	# resolve each task -> EC2; carry workdir/container forward to the worklist
	# ("<nid>\t<label>\t<workdir>\t<container>\t<ec2>").
	printf '==> Tracing %s task(s) to EC2 instances...\n' "$n_in" >&2
	local done_n=0 nid lbl workdir container ec2 where
	while IFS=$'\t' read -r nid lbl workdir container <&3; do
		[ -z "$nid" ] && continue
		done_n=$((done_n + 1))
		ec2="$(_aws_batch_job_to_ec2 "$nid" "$qcache")"
		if [ -z "$ec2" ]; then
			printf '    [%s/%s] %s -> (unresolved; job may have ended)\n' "$done_n" "$n_in" "$nid" >&2
			continue
		fi
		if [ -n "$workdir" ] && [ -n "$container" ]; then
			where="container"
		else
			where="HOST-WIDE (no workdir/container)"
		fi
		printf '    [%s/%s] %s -> %s [%s]\n' "$done_n" "$n_in" "$nid" "$ec2" "$where" >&2
		printf '%s\t%s\t%s\t%s\t%s\n' "$nid" "$lbl" "$workdir" "$container" "$ec2" >>"$worklist"
	done 3<"$intasks"

	local n_tasks
	n_tasks="$(grep -c . "$worklist")"
	[ "$n_tasks" -eq 0 ] && {
		printf 'No tasks resolved to an instance.\n' >&2
		return 1
	}
	printf '==> %s task(s) to check.\n' "$n_tasks" >&2
	case " $probes " in
	*" stall "*)
		printf '==> Stall sampling is sequential: budget roughly ~%ss total. Please wait.\n' \
			"$((n_tasks * _dor_stall_window))" >&2
		;;
	esac

	# diagnose each task, running each selected probe inside its container
	# (or host-wide when the container couldn't be resolved).
	local stuck_list="" out pr marker
	while IFS=$'\t' read -r nid lbl workdir container ec2 <&3; do
		[ -z "$nid" ] && continue
		printf '\n==> [task %s]\n' "$nid"
		printf '    %s\n' "$lbl"
		printf '    instance: %s\n' "$ec2"
		local scoped=1
		if [ -n "$workdir" ] && [ -n "$container" ]; then
			printf '    container: image=%s\n' "$container"
			printf '    workdir  : %s\n' "$workdir"
		else
			scoped=0
			printf '    scope    : HOST-WIDE fallback (no workdir/container; may include co-located tasks)\n'
		fi

		for pr in $probes; do
			printf '    -- probe: %s --\n' "$pr"
			if [ "$scoped" -eq 1 ]; then
				out="$(_dor_run_in_container "$ec2" "$container" "$workdir" "$pattern" "$show_all" "$pr")"
			else
				out="$(_dor_run_remote "$ec2" "$pattern" "$show_all" "$pr")"
			fi
			# each probe marks a flagged task with its own sentinel line
			marker='STUCK pid(s):'
			[ "$pr" = stall ] && marker='>>> FLAG'
			if printf '%s' "$out" | grep -q "$marker"; then
				stuck_list="${stuck_list}${nid}"$'\t'"${lbl}"$'\t'"${pr}"$'\n'
				printf '%s\n' "$out" | sed 's/^/    | /'
			elif printf '%s' "$out" | grep -q '>>> NO-CONTAINER'; then
				# couldn't find the container on the host -- surface it, don't hide it.
				printf '    %s: container not found on host.\n' "$pr"
				printf '%s\n' "$out" | sed 's/^/    | /'
			elif printf '%s' "$out" | grep -q '>>> NO-MATCH'; then
				# The pattern matched no process in this container -- always surface
				# this (and any "what IS running" suggestion) rather than report "ok".
				printf '    %s: pattern not found in this container.\n' "$pr"
				printf '%s\n' "$out" | sed 's/^/    | /'
			elif [ -n "$show_all" ]; then
				printf '%s\n' "$out" | sed 's/^/    | /'
			else
				# matched, nothing flagged: don't be a black box -- echo what was
				# matched (modes) and the one-line verdict.
				printf '    %s: ok (no flag).\n' "$pr"
				if printf '%s' "$out" | grep -q '>>> NOTE:'; then
					# multi-mode match: show the full output incl. the narrow-down hint
					printf '%s\n' "$out" | sed 's/^/    | /'
				else
					printf '%s\n' "$out" \
						| grep -E '^Container id|^Dispatcher\(s\):|^WORKING:|^ACTIVE|^IDLE/STALLED' \
						| sed 's/^/    | /'
				fi
			fi
		done
	done 3<"$worklist"

	# summary
	printf '\n=============================== SUMMARY ===============================\n'
	if [ -z "$stuck_list" ]; then
		printf 'No flagged tasks.\n'
		return 0
	fi
	printf 'FLAGGED task(s):\n'
	printf '%s' "$stuck_list" | while IFS=$'\t' read -r nid lbl pr; do
		[ -z "$nid" ] && continue
		printf '\n  %s  [%s]\n' "$nid" "$pr"
		printf '    - %s\n' "$lbl"
	done
	return 2
}

# --- orchestrator: list a workflow's RUNNING tasks and diagnose --------------
# $1 = workflow id; remaining args forwarded to the diagnoser.
_dor_diagnose_workflow() {
	local wf="$1"
	shift

	local tasks
	tasks="$(_dor_list_running_tasks "$wf")" || return 1
	if [ -z "$tasks" ]; then
		printf 'diagnose_oom_run: no RUNNING tasks found for workflow %s\n' "$wf" >&2
		return 0
	fi

	printf '%s\n' "$tasks" | _dor_diagnose_tasks "$@"
}

# --- orchestrator: resolve a run id then diagnose ----------------------------
# $1 = run id; remaining args forwarded to the diagnoser.
_dor_diagnose_run_id() {
	local run="$1"
	shift

	local wf
	wf="$(_dor_resolve_workflow_id "$run")" || return 1
	[ -z "$wf" ] && {
		printf 'diagnose_oom_run: could not resolve a workflow ID for run %s\n' "$run" >&2
		return 1
	}

	_dor_diagnose_workflow "$wf" "$@"
}

# =============================================================================
# diagnose_oom_run command implementation
# =============================================================================
_dor_main() {
	# Subcommand and help forms.
	case "${1:-}" in
	-h | --help | "")
		_dor_usage
		[ -z "${1:-}" ] && return 2 || return 0
		;;
	list)
		shift
		_dor_list_running_tasks "$@"
		return
		;;
	tasks)
		shift
		_dor_diagnose_tasks "$@"
		return
		;;
	esac

	# Flag form: --run-id / --workflow-id, remaining args -> diagnoser.
	local run_id="" wf_id=""
	local -a rest=()
	while [ $# -gt 0 ]; do
		case "$1" in
		--run-id)
			[ $# -ge 2 ] || {
				printf 'diagnose_oom_run: --run-id requires a value\n' >&2
				return 2
			}
			run_id="$2"
			shift 2
			;;
		--run-id=*)
			run_id="${1#*=}"
			shift
			;;
		--workflow-id)
			[ $# -ge 2 ] || {
				printf 'diagnose_oom_run: --workflow-id requires a value\n' >&2
				return 2
			}
			wf_id="$2"
			shift 2
			;;
		--workflow-id=*)
			wf_id="${1#*=}"
			shift
			;;
		*)
			rest+=("$1")
			shift
			;;
		esac
	done

	if [ -n "$run_id" ] && [ -n "$wf_id" ]; then
		printf 'diagnose_oom_run: specify only one of --run-id or --workflow-id\n' >&2
		return 2
	fi
	if [ -z "$run_id" ] && [ -z "$wf_id" ]; then
		printf 'diagnose_oom_run: specify --run-id ID, --workflow-id ID, or a subcommand (list|tasks)\n\n' >&2
		_dor_usage
		return 2
	fi

	if [ -n "$run_id" ]; then
		_dor_diagnose_run_id "$run_id" ${rest[@]+"${rest[@]}"}
	else
		_dor_diagnose_workflow "$wf_id" ${rest[@]+"${rest[@]}"}
	fi
}

# =============================================================================
# Public: find which workflow/run owns a task with a given tag
# -----------------------------------------------------------------------------
# Usage:
#   find_run_by_task_tag [--status S|ALL] [--max N] [--all] <tag>
#     --status S   only scan workflows in status S (default RUNNING; ALL = any)
#     --max N      scan at most N workflows (default 200)
#     --all        report every matching run (default: stop at the first)
#
# Required environment: API_ACCESS_TOKEN, WORKSPACE_ID, API_ENDPOINT
# =============================================================================
find_run_by_task_tag() {
	local status_filter="RUNNING" max_wf=200 find_all=0 tag=""
	while [ $# -gt 0 ]; do
		case "$1" in
		--status)
			[ -n "${2:-}" ] || {
				printf 'Error: --status requires a value.\n' >&2
				return 2
			}
			status_filter="$2"
			shift 2
			;;
		--status=*)
			status_filter="${1#*=}"
			shift
			;;
		--max)
			[ -n "${2:-}" ] || {
				printf 'Error: --max requires a value.\n' >&2
				return 2
			}
			max_wf="$2"
			shift 2
			;;
		--max=*)
			max_wf="${1#*=}"
			shift
			;;
		--all)
			find_all=1
			shift
			;;
		-h | --help)
			printf 'Usage: find_run_by_task_tag [--status S|ALL] [--max N] [--all] <tag>\n'
			return 0
			;;
		-*)
			printf 'Unknown option: %s\n' "$1" >&2
			return 2
			;;
		*)
			if [ -n "$tag" ]; then
				printf 'Error: too many arguments.\n' >&2
				return 2
			fi
			tag="$1"
			shift
			;;
		esac
	done

	[ -z "$tag" ] && {
		printf 'Error: missing required <tag> argument.\n' >&2
		printf 'Usage: find_run_by_task_tag [--status S|ALL] [--max N] [--all] <tag>\n' >&2
		return 2
	}
	_dor_preflight curl jq awk || return 1

	local auth=(-H "Authorization: Bearer $API_ACCESS_TOKEN")
	local ep="${API_ENDPOINT%/}"
	local offset=0 wtotal page rows found=0
	local wid wname wstatus tpage matches

	printf '==> Scanning %s workflow(s) for a task tagged like "%s"...\n' \
		"$status_filter" "$tag" >&2

	while [ "$offset" -lt "$max_wf" ]; do
		page="$(curl -fsSL --get "${auth[@]}" \
			--data-urlencode "max=100" \
			--data-urlencode "offset=$offset" \
			--data-urlencode "workspaceId=$WORKSPACE_ID" \
			"$ep/workflow")" || {
			printf 'find_run_by_task_tag: workflow list request failed at offset %s.\n' "$offset" >&2
			return 1
		}

		wtotal="$(jq -r '.totalSize // .total // 0' <<<"$page")"
		rows="$(jq -r '.workflows[].workflow | "\(.id)\t\(.runName)\t\(.status)"' <<<"$page")"
		[ -z "$rows" ] && break

		while IFS=$'\t' read -r wid wname wstatus; do
			[ -z "$wid" ] && continue
			if [ "$status_filter" != "ALL" ] && [ "$wstatus" != "$status_filter" ]; then
				continue
			fi

			# Server-side search narrows the task set; confirm the tag client-side.
			tpage="$(curl -fsSL --get "${auth[@]}" \
				--data-urlencode "max=100" \
				--data-urlencode "search=$tag" \
				--data-urlencode "workspaceId=$WORKSPACE_ID" \
				"$ep/workflow/$wid/tasks")" || continue
			matches="$(jq -r --arg t "$tag" '
				.tasks[]? | (.task // .)
				| select((.tag // "") | contains($t))
				| "\(.nativeId)\t\(.tag)\t\(.process)\t\(.status)"' <<<"$tpage")"

			if [ -n "$matches" ]; then
				found=1
				printf '\n=== MATCH ===\n'
				printf '  workflow id : %s\n' "$wid"
				printf '  run name    : %s\n' "$wname"
				printf '  run status  : %s\n' "$wstatus"
				printf '  matching task(s):\n'
				printf '%s\n' "$matches" | awk -F'\t' \
					'{printf "    - nativeId=%s  tag=%s  step=%s  status=%s\n", $1, $2, $3, $4}'
				[ "$find_all" -eq 0 ] && return 0
			fi
		done <<<"$rows"

		offset=$((offset + 100))
		[ "$offset" -ge "$wtotal" ] && break
	done

	if [ "$found" -eq 0 ]; then
		printf 'No %s workflow with a task tagged like "%s" found (scanned up to %s).\n' \
			"$status_filter" "$tag" "$max_wf" >&2
		printf 'Broaden the search, e.g.: find_run_by_task_tag --status ALL --max 1000 %q\n' "$tag" >&2
		return 1
	fi
}

# =============================================================================
# Public script entry point
# -----------------------------------------------------------------------------
# This is the single place where externally callable commands are listed.
# Keep implementations above this dispatcher; add new public commands
# by adding one case arm here and one help line in _xsh_usage.
# =============================================================================
_xsh_usage() {
	cat <<'EOF'
Usage:
  x.sh <command> [args...]

Commands:
  open_task_shell <job_id>
      Trace a Batch job to its EC2 instance and open an SSM session.

  scan_oom_processes [--all|-a] [--match|-m TAG] [-p PATTERN] [PATTERN]
      Check for processes stuck after child OOM kills. procps-free (raw /proc),
      so it runs on a host or docker-exec'd inside a task container.

  scan_stall_processes [--window S] [-p PATTERN] [--all] [PATTERN]
      Fast STALL check for split-pipe jobs (HUNG / crash-loop / degraded), with
      OOM cause attribution. No long sampling window needed. procps-free, so it
      runs on the host or inside the task container.

  diagnose_run [--check oom|stall|all] ...
      Orchestrate run/workflow/task diagnosis, docker-exec'ing the chosen
      probe(s) INSIDE each task's own container (default stall) so co-located
      tasks don't pollute each other. diagnose_stall_run and diagnose_oom_run
      are aliases pinned to one probe.

  find_run_by_task_tag [--status S|ALL] [--max N] [--all] <tag>
      Find which workflow/run owns a task with the given tag.

  show_star_progress --fastq FILE --progress-file FILE [--sample-reads N]
      Estimate STAR alignment progress and ETA from its Log.progress.out.

  show_task_star_progress --workflow-id <id> --native-id <nativeId>
      Resolve a task's workdir + container image, trace it to its EC2
      instance, then docker exec into the task container and run
      show_star_progress on the task's barcode_head FASTQ + progress file.

  show_samtools_sort_progress --pid PID [--interval S] [--window N] [--out-gb GB]
      Live whole-job progress + ETA for a running `samtools sort` (Linux;
      reads /proc/<pid>). Run on the host where the process lives.

  help
      Show this help message.

Compatibility aliases (all still accepted):
  Dash-case spelling of every command (e.g. show-star-progress), plus the
  pre-rename legacy names:
    aws_ssh_job_instance      -> open_task_shell
    find_stuck_oom_processes  -> scan_oom_processes
    star_progress             -> show_star_progress
    star_progress_task        -> show_task_star_progress
EOF
}

_xsh_main() {
	local entrypoint="${1:-}"

	case "$entrypoint" in
	"" | help | -h | --help)
		_xsh_usage
		[ -z "$entrypoint" ] && return 2 || return 0
		;;
	open_task_shell | open-task-shell | aws_ssh_job_instance | aws-ssh-job-instance)
		shift
		open_task_shell "$@"
		;;
	scan_oom_processes | scan-oom-processes | find_stuck_oom_processes | find-stuck-oom-processes)
		shift
		scan_oom_processes "$@"
		;;
	scan_stall_processes | scan-stall-processes)
		shift
		scan_stall_processes "$@"
		;;
	diagnose_run | diagnose-run)
		shift
		_dor_main "$@"
		;;
	diagnose_stall_run | diagnose-stall-run)
		shift
		_DOR_DEFAULT_CHECK=stall _dor_main "$@"
		;;
	diagnose_oom_run | diagnose-oom-run)
		shift
		_DOR_DEFAULT_CHECK=oom _dor_main "$@"
		;;
	find_run_by_task_tag | find-run-by-task-tag)
		shift
		find_run_by_task_tag "$@"
		;;
	show_star_progress | show-star-progress | star_progress | star-progress)
		shift
		show_star_progress "$@"
		;;
	show_task_star_progress | show-task-star-progress | star_progress_task | star-progress-task)
		shift
		show_task_star_progress "$@"
		;;
	show_samtools_sort_progress | show-samtools-sort-progress)
		shift
		show_samtools_sort_progress "$@"
		;;
	*)
		printf 'x.sh: unknown command: %s\n\n' "$entrypoint" >&2
		_xsh_usage >&2
		return 2
		;;
	esac
}

# =============================================================================
# Internal: find a running STAR process aligning a given FASTQ
# -----------------------------------------------------------------------------
# Walks /proc/<pid>/cmdline (NUL-separated args, joined with spaces) and prints
# "<pid>  <cmdline>" for every process whose command contains both "STAR" and
# the FASTQ's basename. Uses /proc directly so it needs no pgrep/procps flags,
# which matters because this is shipped into the task container. Returns 0 if at
# least one match was found, 1 otherwise.
#   $1 = FASTQ path STAR is expected to be reading
# =============================================================================
_sp_star_running() {
	local fastq="$1" base cmdfile pid cmd found=1
	base="${fastq##*/}"
	[ -d /proc ] || return 1
	# Let `find` do the /proc/<pid> matching so this never trips a shell's
	# no-match glob behaviour (zsh aborts on it); robust whether sourced into
	# bash or zsh, or shipped into the container's `bash -s`.
	while IFS= read -r cmdfile; do
		[ -r "$cmdfile" ] || continue
		cmd="$(tr '\0' ' ' <"$cmdfile" 2>/dev/null)"
		case "$cmd" in
		*STAR*) ;;
		*) continue ;;
		esac
		case "$cmd" in
		*"$base"*)
			pid="${cmdfile#/proc/}"
			printf '%s  %s\n' "${pid%/cmdline}" "$cmd"
			found=0
			;;
		esac
	done <<EOF
$(find /proc -maxdepth 2 -regex '/proc/[0-9]+/cmdline' 2>/dev/null)
EOF
	return $found
}

# =============================================================================
# Public: estimate STAR alignment progress and ETA
# -----------------------------------------------------------------------------
# STAR writes a running counter to its Log.progress.out, but reports neither a
# percentage nor a finish time because it never knows the total read count up
# front. This estimates both: it samples the first --sample-reads records of the
# input FASTQ to derive average bytes/read, scales that by the full file size to
# estimate the total read count, then combines that with the reads-processed and
# reads/hour figures from the last line of the progress log to print percent
# complete, reads remaining, and an ETA.
#
# Usage:
#   show_star_progress --fastq FILE --progress-file FILE [--sample-reads N]
#     --fastq FILE          Input FASTQ fed to STAR (sampled for size estimation)
#     --progress-file FILE  STAR Log.progress.out to read the latest counters from
#     --sample-reads N      Reads to sample for the bytes/read estimate (default 100000)
#
# Note: uses `stat -c` (GNU/Linux); intended to run on the compute host.
# =============================================================================
show_star_progress() {
	local fastq=""
	local progress_file=""
	local sample_reads=100000

	usage() {
		cat <<EOF
Usage:
  show_star_progress --fastq FILE --progress-file FILE [OPTIONS]

Required:
  --fastq FILE            Input FASTQ file
  --progress-file FILE    Log progress file

Optional:
  --sample-reads N        Number of reads to sample for size estimation
                          (default: 100000)

  -h, --help              Show this help message

Examples:
  show_star_progress \
    --fastq barcode_head.fastq \
    --progress-file barcode_headLog.progress.out

  show_star_progress \
    --fastq barcode_head.fastq \
    --progress-file barcode_headLog.progress.out \
    --sample-reads 500000
EOF
	}

	while [[ $# -gt 0 ]]; do
		case "$1" in
		--fastq)
			fastq="$2"
			shift 2
			;;
		--progress-file)
			progress_file="$2"
			shift 2
			;;
		--sample-reads)
			sample_reads="$2"
			shift 2
			;;
		-h | --help)
			usage
			return 0
			;;
		*)
			echo "Unknown option: $1" >&2
			usage >&2
			return 1
			;;
		esac
	done

	[[ -z "$fastq" ]] && {
		echo "Missing required argument: --fastq" >&2
		usage >&2
		return 1
	}

	[[ -z "$progress_file" ]] && {
		echo "Missing required argument: --progress-file" >&2
		usage >&2
		return 1
	}

	# Guard FIRST: only report progress if STAR is actually aligning this FASTQ.
	# This runs before the file-existence checks because STAR liveness is the
	# real precondition -- if STAR isn't running, the FASTQ/progress paths being
	# present or absent is irrelevant and the numbers would be stale anyway. The
	# check reads /proc, not the files, so it works even if the FASTQ is a pipe
	# or has since been removed.
	local star_procs
	star_procs="$(_sp_star_running "$fastq")"
	if [[ -z "$star_procs" ]]; then
		echo "No running STAR process is aligning ${fastq##*/}." >&2
		echo "(STAR may have finished or not yet started; progress numbers would be stale.)" >&2
		return 1
	fi
	echo "STAR process    : $(printf '%s' "$star_procs" | head -1 | awk '{print $1}') (running)"

	[[ ! -f "$fastq" ]] && {
		echo "FASTQ not found: $fastq" >&2
		return 1
	}

	[[ ! -f "$progress_file" ]] && {
		echo "Progress file not found: $progress_file" >&2
		return 1
	}

	local processed
	processed=$(tail -1 "$progress_file" | awk '{print $5}')

	local speed
	speed=$(tail -1 "$progress_file" | awk '{print $4}')

	local bytes
	bytes=$(head -n $((sample_reads * 4)) "$fastq" | wc -c)

	local size
	size=$(stat -c %s "$fastq")

	local estimated_total
	# estimated_total_reads = total_file_size / average_bytes_per_read
	estimated_total=$(awk \
		-v b="$bytes" \
		-v s="$size" \
		-v r="$sample_reads" \
		'BEGIN { printf "%.0f", s/(b/r) }')

	awk \
		-v p="$processed" \
		-v t="$estimated_total" \
		-v speed="$speed" \
		-v size="$size" '
    BEGIN {
        speed_reads_per_hour = speed * 1000000

        pct = 100 * p / t
        rem = t - p
        eta = rem / speed_reads_per_hour

        printf "FASTQ size      : %.2f GB\n", size / 1024 / 1024 / 1024
        printf "STAR speed      : %.1f M reads/hour\n", speed
        printf "Processed reads : %'\''d\n", p
        printf "Estimated total : %'\''d\n", t
        printf "Progress        : %.2f%%\n", pct
        printf "Remaining reads : %'\''d\n", rem
        printf "ETA             : %.1f hours\n", eta
    }'
}

# =============================================================================
# Public: run show_star_progress for a task identified by workflow + nativeId
# -----------------------------------------------------------------------------
# Ties the pieces together so you never assemble the FASTQ / progress-file paths
# by hand. Given a workflow ID and a task's nativeId (AWS Batch job UUID) it:
#   1. resolves the task's work directory AND container image via the API
#      (same backend talks to; reuses this toolbox's API_* env so no),
#   2. traces the nativeId to its backing EC2 instance (_aws_batch_job_to_ec2),
#   3. on that host, finds the running task container by its image tag
#      (sudo docker ps | grep <tag>), then `docker exec`s into it and there
#      converts the s3:// workdir to its /fusion/s3 mount, locates the *_ALIGN
#      output directory, and runs show_star_progress on the fixed process/barcode_head
#      FASTQ + Log.progress.out paths.
#
# Usage:
#   show_task_star_progress --workflow-id <id> --native-id <nativeId>
#
# Required environment: API_ACCESS_TOKEN, WORKSPACE_ID, API_ENDPOINT
# Requirements: aws (SSM), curl, jq.
# =============================================================================

# --- API: resolve a task's workdir + container image by nativeId -------------
# Emits "<workdir>\t<container-image>" on stdout; errors on stderr. Reuses the
# same paginated /workflow/<id>/tasks endpoint as _dor_list_running_tasks.
_sp_task_info() {
	local wf="$1" nid="$2"
	_dor_preflight curl jq || return 1

	local auth=(-H "Authorization: Bearer $API_ACCESS_TOKEN")
	local ep="${API_ENDPOINT%/}"
	local offset=0 total page row

	while :; do
		page="$(curl -fsSL --get "${auth[@]}" \
			--data-urlencode "max=100" \
			--data-urlencode "offset=$offset" \
			--data-urlencode "workspaceId=$WORKSPACE_ID" \
			"$ep/workflow/$wf/tasks")" || {
			printf 'show_task_star_progress: API request failed at offset %s for workflow %s\n' "$offset" "$wf" >&2
			return 1
		}

		total="$(jq -r '.total // 0' <<<"$page")"
		row="$(jq -r --arg n "$nid" '
			.tasks[] | (.task // .)
			| select((.nativeId | tostring) == $n)
			| "\(.workdir // "")\t\(.container // "")"' <<<"$page" | head -1)"
		[ -n "${row%%$'\t'*}" ] && {
			printf '%s\n' "$row"
			return 0
		}

		offset=$((offset + 100))
		[ "$offset" -ge "$total" ] && break
	done

	printf 'show_task_star_progress: no task with nativeId %s found in workflow %s\n' "$nid" "$wf" >&2
	return 1
}

# --- container driver: shipped INTO the task container and run there ---------
# Converts the task's s3:// workdir to its /fusion/s3 mount, finds the single
# *_ALIGN output directory under it, and invokes show_star_progress on the fixed
# barcode_head FASTQ + Log.progress.out paths. Runs inside the container so it
# sees the same fusion mount and GNU coreutils the task itself used.
#   $1 = s3:// work directory of the task
_sp_container_driver() {
	local workdir="$1"
	local fusion="/fusion/s3/${workdir#s3://}"

	local align_dir
	align_dir="$(ls -d "$fusion"/*_ALIGN 2>/dev/null | head -1)"
	if [ -z "$align_dir" ]; then
		echo "No *_ALIGN directory found under $fusion" >&2
		return 1
	fi

	echo "Work directory  : $fusion"
	echo "ALIGN directory : $align_dir"
	echo
	show_star_progress \
		--fastq "$align_dir/process/barcode_head.fastq" \
		--progress-file "$align_dir/process/barcode_headLog.progress.out"
}

# --- ship + run: locate the container on the host, exec show_star_progress in it --
# Builds two layers and ships the outer one to the EC2 instance via SSM:
#   inner (runs in the container): show_star_progress + _sp_container_driver, base64
#     encoded so it survives the docker-exec stdin pipe without quoting hazards.
#   outer (runs on the host):      find THIS task's container (by the work dir
#     embedded in the container's launch config, falling back to image tag),
#     decode the inner script, and pipe it into `sudo docker exec -i <cid> bash -s`.
#   $1 = EC2 instance id   $2 = container image ref   $3 = s3:// work directory
_sp_run_remote() {
	local instance="$1" image="$2" workdir="$3"
	local tag="${image##*:}"
	local fusion="/fusion/s3/${workdir#s3://}"
	local inner_src inner_script b64 host_script

	inner_src="$(declare -f show_star_progress _sp_star_running _sp_container_driver)" || return 1
	inner_script="set -u
${inner_src}
_sp_container_driver $(printf '%q' "$workdir")"
	b64="$(printf '%s' "$inner_script" | base64 | tr -d '\n')"

	# Local interpolation injects the image/tag/payload as quoted literals; every
	# remote-evaluated $ is escaped (\$) so it survives into the host script.
	host_script="set -u
image=$(printf '%q' "$image")
tag=$(printf '%q' "$tag")
fusion=$(printf '%q' "$fusion")
b64=$(printf '%q' "$b64")

# Pick the container running THIS task, not just any container sharing the
# image tag. The image tag is NOT unique per task -- a host commonly runs
# several containers of the same image, so 'grep tag | head -1' can land in a
# different task's container (where this task's STAR is invisible, since each
# container has its own PID namespace). Every Nextflow/fusion task container is
# launched to run <workdir>/.command.run, so the task's unique work directory is
# embedded in the container's immutable launch config: inspect each running
# container and match on it. This is exact and independent of process/clock
# state (unlike matching container start time to the task's execution time,
# which breaks when a container outlives or predates the task).
cid=\"\"
for c in \$(sudo docker ps --no-trunc --format '{{.ID}}'); do
	if sudo docker inspect \"\$c\" 2>/dev/null | grep -qF -- \"\$fusion\"; then
		cid=\$c
		break
	fi
done
if [ -z \"\$cid\" ]; then
	# Fallback: first running container matching the image tag (old behaviour).
	cid=\$(sudo docker ps --no-trunc | grep -F -- \"\$tag\" | awk '{print \$1}' | head -1)
	[ -n \"\$cid\" ] && echo \"WARN: no container config referenced \$fusion; falling back to first \$tag container (\$cid). It may belong to a different task.\" >&2
fi
if [ -z \"\$cid\" ]; then
	echo \"No running container found for image \$image (searched by work dir and tag \$tag)\" >&2
	exit 1
fi
echo \"Container image : \$image\"
echo \"Container id    : \$cid\"
echo
printf '%s' \"\$b64\" | base64 -d | sudo docker exec -i \"\$cid\" bash -s"

	_xsh_ssm_run "$instance" "$host_script" "show_star_progress $tag"
}

# --- public orchestrator -----------------------------------------------------
show_task_star_progress() {
	local usage
	read -r -d '' usage <<'EOF' || true
Usage: show_task_star_progress --workflow-id <id> --native-id <nativeId>

Resolve a STAR alignment task's work directory and container image via the
Tower API, trace its nativeId to the backing EC2 instance, find the running task
container there, and run show_star_progress inside it against the task's barcode_head
FASTQ and Log.progress.out.

Options:
  --workflow-id <id>   Tower workflow ID that owns the task.
  --native-id <id>     Task nativeId (AWS Batch job UUID).
  -h, --help           Show this help message and exit.

Required environment: API_ACCESS_TOKEN, WORKSPACE_ID, API_ENDPOINT
Requirements: aws (SSM), curl, jq.

Example:
  show_task_star_progress \
    --workflow-id 2xAbCdEfGhIjKl \
    --native-id aa00a1e2-1e96-4cbb-a670-3b33c5ac356d
EOF

	local wf="" nid=""
	while [ $# -gt 0 ]; do
		case "$1" in
		--workflow-id)
			[ $# -ge 2 ] || {
				printf 'show_task_star_progress: --workflow-id requires a value\n' >&2
				return 2
			}
			wf="$2"
			shift 2
			;;
		--workflow-id=*)
			wf="${1#*=}"
			shift
			;;
		--native-id)
			[ $# -ge 2 ] || {
				printf 'show_task_star_progress: --native-id requires a value\n' >&2
				return 2
			}
			nid="$2"
			shift 2
			;;
		--native-id=*)
			nid="${1#*=}"
			shift
			;;
		-h | --help)
			printf '%s\n' "$usage"
			return 0
			;;
		-*)
			printf 'Error: unknown option %s\n\n' "$1" >&2
			printf '%s\n' "$usage" >&2
			return 1
			;;
		*)
			printf 'Error: unexpected argument %s\n\n' "$1" >&2
			printf '%s\n' "$usage" >&2
			return 1
			;;
		esac
	done

	[ -z "$wf" ] && {
		printf 'Error: missing required option --workflow-id.\n\n' >&2
		printf '%s\n' "$usage" >&2
		return 1
	}
	[ -z "$nid" ] && {
		printf 'Error: missing required option --native-id.\n\n' >&2
		printf '%s\n' "$usage" >&2
		return 1
	}
	command -v aws >/dev/null 2>&1 || {
		printf 'show_task_star_progress: required command not found: aws\n' >&2
		return 1
	}

	printf '==> Resolving work directory + container image for task %s in workflow %s...\n' "$nid" "$wf" >&2
	local info workdir image
	info="$(_sp_task_info "$wf" "$nid")" || return 1
	workdir="${info%%$'\t'*}"
	image="${info#*$'\t'}"
	if [ -z "$workdir" ] || [ -z "$image" ]; then
		printf 'show_task_star_progress: task %s is missing a workdir or container image (got workdir=%q image=%q).\n' \
			"$nid" "$workdir" "$image" >&2
		return 1
	fi
	printf '    workdir: %s\n' "$workdir" >&2
	printf '    image  : %s\n' "$image" >&2

	printf '==> Tracing nativeId %s to its EC2 instance...\n' "$nid" >&2
	local ec2
	ec2="$(_aws_batch_job_to_ec2 "$nid")" || {
		printf 'show_task_star_progress: could not trace nativeId %s to an EC2 instance.\n' "$nid" >&2
		return 1
	}
	printf '    EC2 instance: %s\n' "$ec2" >&2

	printf '==> Running show_star_progress inside the task container on %s...\n' "$ec2" >&2
	_sp_run_remote "$ec2" "$image" "$workdir"
}

# =============================================================================
# Public: whole-job progress + ETA for a running `samtools sort`
# -----------------------------------------------------------------------------
# A name-sort runs in two phases:
#   1. READ/SORT : streams the input, writing sorted temp chunks (-T prefix).
#   2. MERGE     : merges those chunks into the -o output file.
# This measures BOTH and combines them into one overall figure:
#
#     done  = bytes_read (input offset)  +  bytes_written (output size)
#     total = input_size                 +  output_target
#     overall% = done / total
#
# Printed every --interval seconds until Ctrl+C:
#
#   [ts] overall P% (D/T GB) [phase] | chunks N | avg(K) R MB/s -> ETA | now R MB/s -> ETA
#
#   phase   : reading | merging | finalizing(cpu) | done
#   avg(K)  : smoothed moving average of the overall rate over the last
#             --window samples (kept history). Bigger window = smoother/laggier.
#   now     : instantaneous overall rate over the most recent interval.
#
# Notes:
#  * output_target is estimated as the input size (override with --out-gb).
#    The %/ETA are approximate around the read->merge handoff and during the
#    CPU-bound in-memory final sort (rate goes ~0 -> ETA shows n/a, by design).
#  * Linux-only: reads /proc/<pid>/{cmdline,fd,fdinfo}; needs bash 4+. Run it on
#    the host (or inside the container) where the samtools sort process lives.
#
# Usage:
#   show_samtools_sort_progress --pid PID [--interval SECONDS] [--window SAMPLES] [--out-gb GB]
#   show_samtools_sort_progress -p PID [-i SECONDS] [-w SAMPLES] [-o GB]
#
#   --pid,      -p   process id of the samtools sort        (REQUIRED)
#   --interval, -i   seconds between samples                (default 10)
#   --window,   -w   samples in the smoothing window        (default 6)
#   --out-gb,   -o   override estimated output size in GB   (default = input size)
#   --help,     -h   show this help
# =============================================================================
show_samtools_sort_progress() {
	local PID="" INTERVAL=10 WINDOW=6 OUT_GB=""

	_spf_usage() {
		cat <<'USAGE'
Usage: show_samtools_sort_progress --pid PID [--interval SECONDS] [--window SAMPLES] [--out-gb GB]
  --pid,      -p   process id of the samtools sort        (REQUIRED)
  --interval, -i   seconds between samples                (default 10)
  --window,   -w   samples in the smoothing window        (default 6)
  --out-gb,   -o   override estimated output size in GB   (default = input size)
  --help,     -h   show this help
USAGE
	}

	# --- parse named parameters -------------------------------------------
	while (($#)); do
		case "$1" in
		-p | --pid)
			PID="$2"
			shift 2
			;;
		-i | --interval)
			INTERVAL="$2"
			shift 2
			;;
		-w | --window)
			WINDOW="$2"
			shift 2
			;;
		-o | --out-gb)
			OUT_GB="$2"
			shift 2
			;;
		--pid=*)
			PID="${1#*=}"
			shift
			;;
		--interval=*)
			INTERVAL="${1#*=}"
			shift
			;;
		--window=*)
			WINDOW="${1#*=}"
			shift
			;;
		--out-gb=*)
			OUT_GB="${1#*=}"
			shift
			;;
		-h | --help)
			_spf_usage
			unset -f _spf_usage
			return 0
			;;
		*)
			echo "show_samtools_sort_progress: unknown option '$1'" >&2
			_spf_usage
			unset -f _spf_usage
			return 2
			;;
		esac
	done
	unset -f _spf_usage

	# --- validate ----------------------------------------------------------
	[[ -n "$PID" ]] || {
		echo "show_samtools_sort_progress: --pid is required" >&2
		return 2
	}
	[[ "$PID" =~ ^[0-9]+$ ]] || {
		echo "show_samtools_sort_progress: --pid must be an integer" >&2
		return 2
	}
	[[ "$INTERVAL" =~ ^[0-9]+$ ]] || {
		echo "show_samtools_sort_progress: --interval must be an integer" >&2
		return 2
	}
	[[ "$WINDOW" =~ ^[0-9]+$ && "$WINDOW" -ge 1 ]] || {
		echo "show_samtools_sort_progress: --window must be a positive integer" >&2
		return 2
	}
	[[ -z "$OUT_GB" || "$OUT_GB" =~ ^[0-9]+(\.[0-9]+)?$ ]] || {
		echo "show_samtools_sort_progress: --out-gb must be a number" >&2
		return 2
	}
	[[ -d /proc/$PID ]] || {
		echo "No process with PID $PID" >&2
		return 1
	}

	# --- parse the samtools command line: input, output, temp prefix -------
	local -a ARGS
	local IN OUT="" TMP="" i
	mapfile -d '' ARGS <"/proc/$PID/cmdline"
	for ((i = 0; i < ${#ARGS[@]}; i++)); do
		[[ "${ARGS[i]}" == "-o" ]] && OUT="${ARGS[i + 1]:-}"
		[[ "${ARGS[i]}" == "-T" ]] && TMP="${ARGS[i + 1]:-}"
	done
	IN="${ARGS[-1]:-}"
	[[ -n "$IN" && -e "$IN" ]] || {
		echo "Could not determine input file (got '$IN')" >&2
		return 1
	}

	local SIZE TARGET TOTAL
	SIZE=$(stat -c %s "$IN")
	if [[ -n "$OUT_GB" ]]; then
		TARGET=$(awk "BEGIN{printf \"%d\", $OUT_GB*1e9}")
	else
		TARGET=$SIZE
	fi
	TOTAL=$((SIZE + TARGET))

	# --- local helpers -----------------------------------------------------
	_spf_find_fd() { # echo fd number pointing at input, or nothing
		local l
		for l in /proc/$PID/fd/*; do
			[[ "$(readlink "$l" 2>/dev/null)" == "$IN" ]] && {
				basename "$l"
				return 0
			}
		done
		return 1
	}
	_spf_chunks() { # count temp chunk files (excludes the output)
		[[ -n "$TMP" ]] || {
			echo 0
			return
		}
		(
			shopt -s nullglob
			local f=("$TMP".*.bam)
			echo "${#f[@]}"
		)
	}
	_spf_eta() {
		awk -v s="$1" 'BEGIN{
			if (s < 0 || s == "" || s != s) { print "n/a"; exit }
			h = int(s/3600); m = int((s%3600)/60); sec = int(s%60);
			if (h > 0)      printf "%dh %dm %ds", h, m, sec;
			else if (m > 0) printf "%dm %ds", m, sec;
			else            printf "%ds", sec;
		}'
	}

	local FD
	FD=$(_spf_find_fd || true)

	printf 'PID         : %s\n' "$PID"
	printf 'input       : %s\n' "$IN"
	printf 'output      : %s\n' "${OUT:-<unknown>}"
	printf 'in size     : %.1f GB    output target: %.1f GB (estimate%s)\n' \
		"$(awk "BEGIN{print $SIZE/1e9}")" "$(awk "BEGIN{print $TARGET/1e9}")" \
		"$([[ -n "$OUT_GB" ]] && echo ', user-set')"
	printf 'interval    : %ss   window: %s samples (~%ss)   Ctrl+C to stop\n' \
		"$INTERVAL" "$WINDOW" "$((INTERVAL * WINDOW))"
	echo "--------------------------------------------------------------------------------"

	# Ctrl+C sets a flag (won't kill the shell when sourced)
	local _spf_stop=0
	trap '_spf_stop=1' INT

	local -a hist_t=() hist_done=()
	local now_t ts pos out chunks done pct gbdone gbtotal phase avg_str now_str
	local prev_done="" prev_pos="" prev_t="" wt0 wd0

	while ((_spf_stop == 0)); do
		now_t=$(date +%s.%N)
		ts=$(date +%H:%M:%S)

		if [[ ! -d /proc/$PID ]]; then
			echo "[$ts] process $PID no longer running — job finished or exited."
			break
		fi

		# re-resolve input fd; it disappears when reading is fully done
		if [[ -z "$FD" || "$(readlink "/proc/$PID/fd/$FD" 2>/dev/null)" != "$IN" ]]; then
			FD=$(_spf_find_fd || true)
		fi

		# bytes read (input offset; clamp to SIZE; full size if fd already closed)
		if [[ -n "$FD" && -r "/proc/$PID/fdinfo/$FD" ]]; then
			pos=$(awk '/^pos:/{print $2}' "/proc/$PID/fdinfo/$FD")
			((pos > SIZE)) && pos=$SIZE
		else
			pos=$SIZE
		fi

		# bytes written (output file size) + remaining temp chunks
		out=0
		[[ -n "$OUT" && -e "$OUT" ]] && out=$(stat -c %s "$OUT")
		chunks=$(_spf_chunks)

		done=$((pos + out))
		((done > TOTAL)) && done=$TOTAL # guard if output exceeds the estimate

		pct=$(awk "BEGIN{printf \"%.1f\", $done/$TOTAL*100}")
		gbdone=$(awk "BEGIN{printf \"%.1f\", $done/1e9}")
		gbtotal=$(awk "BEGIN{printf \"%.1f\", $TOTAL/1e9}")

		# rolling history of overall `done` bytes
		hist_t+=("$now_t")
		hist_done+=("$done")
		while ((${#hist_t[@]} > WINDOW)); do
			hist_t=("${hist_t[@]:1}")
			hist_done=("${hist_done[@]:1}")
		done

		# phase label from per-tick movement
		if [[ -n "$prev_done" ]]; then
			if [[ -n "$FD" ]] && ((pos > prev_pos && pos < SIZE)); then
				phase="reading"
			elif ((done > prev_done)); then
				phase="merging"
			elif ((done >= TOTAL)); then
				phase="done"
			else phase="finalizing(cpu)"; fi
		else
			{ [[ -n "$FD" ]] && ((pos < SIZE)); } && phase="reading" || phase="merging"
		fi

		# smoothed avg over the window
		wt0="${hist_t[0]}"
		wd0="${hist_done[0]}"
		if ((${#hist_t[@]} >= 2)); then
			local ar ae
			ar=$(awk "BEGIN{dt=$now_t-$wt0; dp=$done-$wd0; printf \"%.1f\", (dt>0)?(dp/dt)/1e6:0}")
			ae=$(awk "BEGIN{dt=$now_t-$wt0; dp=$done-$wd0; r=(dt>0)?dp/dt:0; print (r>0)?($TOTAL-$done)/r:-1}")
			avg_str="avg(${#hist_t[@]}) ${ar} MB/s -> ETA $(_spf_eta "$ae")"
		else
			avg_str="avg (warming up)"
		fi

		# instantaneous
		if [[ -n "$prev_done" ]]; then
			local nr ne
			nr=$(awk "BEGIN{dt=$now_t-$prev_t; dp=$done-$prev_done; printf \"%.1f\", (dt>0)?(dp/dt)/1e6:0}")
			ne=$(awk "BEGIN{dt=$now_t-$prev_t; dp=$done-$prev_done; r=(dt>0)?dp/dt:0; print (r>0)?($TOTAL-$done)/r:-1}")
			now_str="now ${nr} MB/s -> ETA $(_spf_eta "$ne")"
		else
			now_str="now (need one more sample)"
		fi

		printf '[%s] overall %5s%% (%s/%s GB) [%s] | chunks %s | %s | %s\n' \
			"$ts" "$pct" "$gbdone" "$gbtotal" "$phase" "$chunks" "$avg_str" "$now_str"

		if [[ "$phase" == "done" ]]; then
			echo "[$ts] all bytes accounted for — sort should be wrapping up."
		fi

		prev_done=$done
		prev_pos=$pos
		prev_t=$now_t
		sleep "$INTERVAL"
	done

	trap - INT
	unset -f _spf_find_fd _spf_chunks _spf_eta
	echo "stopped."
}

# Public umbrella: diagnose a run/workflow/task with one or more probes, each
# docker-exec'd INSIDE the task's own container (select with --check oom|stall|all;
# default stall). diagnose_stall_run and diagnose_oom_run pin a single probe via
# _DOR_DEFAULT_CHECK -- a variable, not a positional arg, so every legacy form
# (incl. the list/tasks subcommands) works.
diagnose_run() {
	_dor_main "$@"
}
diagnose_stall_run() {
	_DOR_DEFAULT_CHECK=stall _dor_main "$@"
}
diagnose_oom_run() {
	_DOR_DEFAULT_CHECK=oom _dor_main "$@"
}

# =============================================================================
# Backward-compatible aliases for the pre-rename public names.
# -----------------------------------------------------------------------------
# These forward to the current verb-first names so anything sourced before the
# rename (interactive shells, scripts, muscle memory) keeps working. The real
# implementations -- and the ones shipped to remote hosts via `declare -f` --
# are the new names; these are thin local pass-throughs only.
# =============================================================================
aws_ssh_job_instance() { open_task_shell "$@"; }
find_stuck_oom_processes() { scan_oom_processes "$@"; }
star_progress() { show_star_progress "$@"; }
star_progress_task() { show_task_star_progress "$@"; }

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
	_xsh_main "$@"
	exit $?
fi
