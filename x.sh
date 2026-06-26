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
#   open_task_shell, scan_oom_processes, diagnose_oom_run
#
# No code is duplicated: the Batch->ECS->EC2 trace lives once in
# _aws_batch_job_to_ec2 (used by both open_task_shell and the diagnoser),
# and the on-host check is scan_oom_processes, shipped to each instance via
# `declare -f` and run there as root over SSM.
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
# Public: on-host OOM-stuck process finder (run this ON the host)
# -----------------------------------------------------------------------------
# Find processes that are hung because the kernel OOM-killed some of their
# children but NOT the process itself, leaving the parent deadlocked. A single
# host can run several instances of the same program at once, each in its own
# memory cgroup; this walks EVERY process matching a pattern, prints its cgroup
# + memory facts, and flags the ones that are stuck (OOM-killed children +
# zombie/defunct children).
#
# Usage:
#   scan_oom_processes [--all|-a] [--match|-m TAG] PATTERN
#   PATTERN is a 'pgrep -f' pattern (or set PROC_PATTERN).
#
# Tunables (env): CGROUP_ROOT (default /sys/fs/cgroup), PROC_PATTERN.
# =============================================================================
scan_oom_processes() {
	local cgroup_root="${CGROUP_ROOT:-/sys/fs/cgroup}"

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
		-h | --help)
			echo "Usage: scan_oom_processes [--all|-a] [--match|-m TAG] PATTERN"
			echo "  PATTERN          'pgrep -f' pattern for the process(es) to inspect"
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
			echo "Unknown option: $1 (use --all, -m TAG, or -h)" >&2
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

	local read_file
	read_file() { cat "$1" 2>/dev/null; }

	local stuck_pids=()
	local pids pid cg base oom_group mem_max mem_cur mem_events zombies oom_kill
	local block is_stuck cmdline matched=0

	pids=$(pgrep -f "$proc_pattern" 2>/dev/null)

	if [ -z "$pids" ]; then
		echo "No processes matching '$proc_pattern' found on this host."
		echo "If you expected one, confirm you are on the right host and that the"
		echo "process is still running."
		return 0
	fi

	for pid in $pids; do
		# Full command line tells us which instance/task this is.
		cmdline=$(tr '\0' ' ' <"/proc/$pid/cmdline" 2>/dev/null)

		# --match: skip matches whose cmdline doesn't contain TAG.
		if [ -n "$cmd_match" ] && [[ "$cmdline" != *"$cmd_match"* ]]; then
			continue
		fi
		matched=1

		# cgroup v2: the unified hierarchy line starts with "0::"
		cg=$(awk -F: '/^0::/{print $3}' "/proc/$pid/cgroup" 2>/dev/null)

		base="${cgroup_root}${cg}"
		oom_group=$(read_file "$base/memory.oom.group")
		mem_max=$(read_file "$base/memory.max")
		mem_cur=$(read_file "$base/memory.current")
		mem_events=$(read_file "$base/memory.events" | tr '\n' ' ')

		# Count zombie/defunct direct children the parent can never reap.
		zombies=$(ps --ppid "$pid" -o stat= 2>/dev/null | grep -c '^Z')

		# Pull the oom_kill counter out of memory.events for the verdict.
		oom_kill=$(printf '%s' "$mem_events" | awk '{for(i=1;i<NF;i++) if($i=="oom_kill") print $(i+1)}')
		oom_kill=${oom_kill:-0}

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
# diagnose_oom_run internals (namespaced _dor_)
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
  diagnose_oom_run --run-id <id> [diagnose-args...]       Resolve run -> workflow, diagnose RUNNING tasks
  diagnose_oom_run --workflow-id <id> [diagnose-args...]  Diagnose a workflow's RUNNING tasks
  diagnose_oom_run list <workflow-id>                     Print "<nativeId><TAB>label" for RUNNING tasks
  diagnose_oom_run tasks [-p PATTERN] [--all] [id...]     Diagnose tasks from stdin/args (the back half)

diagnose-args forwarded to the task diagnoser: [-p PATTERN] [--all]

Required environment: API_ACCESS_TOKEN, WORKSPACE_ID, API_ENDPOINT
Diagnosis pattern: pass -p PATTERN, or set PROC_PATTERN.
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
# Emits "<nativeId>\tsample=...\tstep=..." lines on stdout.
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
		         | "\(.nativeId)\tsample=\(.tag)\tstep=\(.process)"' <<<"$page"

		offset=$((offset + 100))
		[ "$offset" -ge "$total" ] && break
	done
}

# --- diagnostic: run scan_oom_processes on one instance via SSM --------
_dor_run_remote() {
	local instance="$1" pattern="$2" extra="$3"
	local func_src remote_script

	func_src="$(declare -f scan_oom_processes)" || return 1
	remote_script="set -u
${func_src}
scan_oom_processes ${extra} $(printf '%q' "$pattern")"

	_xsh_ssm_run "$instance" "$remote_script" "scan_oom_processes $pattern"
}

# --- diagnostic: diagnose a set of tasks -------------------------------------
# Reads "<nativeId>\t<label>" lines on stdin (or takes native IDs as args),
# groups by EC2 instance, runs scan_oom_processes on each.
_dor_diagnose_tasks() {
	local pattern="${PROC_PATTERN:-}" show_all=""
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
		-a | --all)
			show_all="--all"
			shift
			;;
		-h | --help)
			printf 'Usage: diagnose_oom_run tasks [-p PATTERN] [--all] [nativeId...]\n'
			printf '  Reads "<nativeId><TAB><label>" lines on stdin if no IDs are given.\n'
			printf '  PATTERN defaults to PROC_PATTERN when -p/--pattern is not provided.\n'
			return 0
			;;
		-*)
			printf 'Unknown option: %s\n' "$1" >&2
			return 2
			;;
		*)
			native_ids[${#native_ids[@]}]="$1"
			shift
			;;
		esac
	done

	if [ -z "$pattern" ]; then
		printf 'Error: no process PATTERN provided (pass -p/--pattern PATTERN or set PROC_PATTERN).\n' >&2
		return 2
	fi

	local t
	for t in aws jq awk; do
		command -v "$t" >/dev/null 2>&1 || {
			printf 'Error: %s not found.\n' "$t" >&2
			return 1
		}
	done
	declare -F scan_oom_processes >/dev/null 2>&1 || {
		printf 'Error: scan_oom_processes not defined.\n' >&2
		return 1
	}

	# temp files: input lines, queue->cluster cache, instance->label map
	local intasks qcache mapf
	intasks="$(mktemp)"
	qcache="$(mktemp)"
	mapf="$(mktemp)"
	# Clean up temp files when this function returns. bash uses the RETURN
	# pseudo-signal; zsh has no RETURN trap, but an EXIT trap set inside a
	# function is function-local there and fires on return -- so pick per shell.
	if [ -n "${ZSH_VERSION:-}" ]; then
		trap 'rm -f "$intasks" "$qcache" "$mapf"' EXIT
	else
		trap 'rm -f "$intasks" "$qcache" "$mapf"' RETURN
	fi

	# gather input: from args (label = id) or stdin ("<id><TAB><label>")
	if [ ${#native_ids[@]} -gt 0 ]; then
		local id
		for id in "${native_ids[@]}"; do printf '%s\t%s\n' "$id" "$id" >>"$intasks"; done
	else
		if [ -t 0 ]; then
			printf 'Error: no native IDs given (pass as args or pipe them in).\n' >&2
			return 1
		fi
		# normalise: first whitespace-separated field = id, remainder = label
		awk '{
			id=$1
			lbl=$0; sub(/^[^[:space:]]+[[:space:]]*/, "", lbl)
			if (lbl=="") lbl=id
			print id "\t" lbl
		}' >"$intasks"
	fi

	local n_in
	n_in="$(wc -l <"$intasks" | tr -d ' ')"
	[ "$n_in" -eq 0 ] && {
		printf 'No native IDs to process.\n' >&2
		return 1
	}

	# resolve each task -> EC2; write "<ec2><TAB><label>" to mapf
	printf '==> Tracing %s task(s) to EC2 instances...\n' "$n_in" >&2
	local done_n=0 nid lbl ec2
	while IFS=$'\t' read -r nid lbl <&3; do
		[ -z "$nid" ] && continue
		done_n=$((done_n + 1))
		ec2="$(_aws_batch_job_to_ec2 "$nid" "$qcache")"
		if [ -z "$ec2" ]; then
			printf '    [%s/%s] %s -> (unresolved; job may have ended)\n' "$done_n" "$n_in" "$nid" >&2
			continue
		fi
		printf '    [%s/%s] %s -> %s\n' "$done_n" "$n_in" "$nid" "$ec2" >&2
		printf '%s\t%s\tnativeId=%s\n' "$ec2" "$lbl" "$nid" >>"$mapf"
	done 3<"$intasks"

	local n_inst
	n_inst="$(cut -f1 "$mapf" | sort -u | grep -c .)"
	[ "$n_inst" -eq 0 ] && {
		printf 'No instances resolved.\n' >&2
		return 1
	}
	printf '==> %s unique instance(s) to check.\n' "$n_inst" >&2

	# diagnose each unique instance
	local stuck_list="" instance out
	while IFS= read -r instance <&3; do
		[ -z "$instance" ] && continue
		printf '\n==> [%s] scan_oom_processes "%s"\n' "$instance" "$pattern"
		printf '    tasks on this instance:\n'
		awk -F'\t' -v i="$instance" '$1==i{sub(/^[^\t]*\t/,""); print "      - " $0}' "$mapf"

		out="$(_dor_run_remote "$instance" "$pattern" "$show_all")"
		if printf '%s' "$out" | grep -q 'STUCK pid(s):'; then
			stuck_list="${stuck_list}${instance}"$'\n'
			printf '%s\n' "$out" | sed 's/^/    | /'
		elif [ -n "$show_all" ]; then
			printf '%s\n' "$out" | sed 's/^/    | /'
		else
			printf '    healthy (no stuck process).\n'
		fi
	done 3< <(cut -f1 "$mapf" | sort -u)

	# summary
	printf '\n=============================== SUMMARY ===============================\n'
	if [ -z "$stuck_list" ]; then
		printf 'No stuck instances.\n'
		return 0
	fi
	printf 'STUCK instance(s):\n'
	printf '%s' "$stuck_list" | while IFS= read -r instance; do
		[ -z "$instance" ] && continue
		printf '\n  %s\n' "$instance"
		awk -F'\t' -v i="$instance" '$1==i{sub(/^[^\t]*\t/,""); print "    - " $0}' "$mapf"
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
			rest[${#rest[@]}]="$1"
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

  scan_oom_processes [--all|-a] [--match|-m TAG] PATTERN
      On-host check for processes stuck after child OOM kills.

  diagnose_oom_run ...
      Orchestrate run/workflow/task OOM diagnosis.

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
	diagnose_oom_run | diagnose-oom-run)
		shift
		_dor_main "$@"
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

# Source-compatible wrapper for existing users.
diagnose_oom_run() {
	_dor_main "$@"
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
