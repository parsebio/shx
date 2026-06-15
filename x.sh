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
#   aws_ssh_job_instance, find_stuck_oom_processes, diagnose_oom_run
#
# No code is duplicated: the Batch->ECS->EC2 trace lives once in
# _aws_batch_job_to_ec2 (used by both aws_ssh_job_instance and the diagnoser),
# and the on-host check is find_stuck_oom_processes, shipped to each instance via
# `declare -f` and run there as root over SSM.
#
# Required environment:
#   API_ACCESS_TOKEN   Personal access token (Authorization: Bearer ...).
#   WORKSPACE_ID       Numeric workspace ID.
#   API_ENDPOINT       API base URL.
#   PROC_PATTERN       Default remote process pattern for diagnosis.
#
# Requirements: awscli v2 configured for the target account/region; the SSM
# Session Manager plugin (for aws_ssh_job_instance); jq, curl, awk.
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

# =============================================================================
# Public: open an SSM session on the instance backing a Batch job
# =============================================================================
aws_ssh_job_instance() {
	local usage
	read -r -d '' usage <<'EOF' || true
Usage: aws_ssh_job_instance [-h|--help] <job_id>

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
  aws_ssh_job_instance aa00a1e2-1e96-4cbb-a670-3b33c5ac356d
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
#   find_stuck_oom_processes [--all|-a] [--match|-m TAG] PATTERN
#   PATTERN is a 'pgrep -f' pattern (or set PROC_PATTERN).
#
# Tunables (env): CGROUP_ROOT (default /sys/fs/cgroup), PROC_PATTERN.
# =============================================================================
find_stuck_oom_processes() {
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
			echo "Usage: find_stuck_oom_processes [--all|-a] [--match|-m TAG] PATTERN"
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
		echo "Try: find_stuck_oom_processes --help" >&2
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

# --- diagnostic: run find_stuck_oom_processes on one instance via SSM --------
_dor_run_remote() {
	local instance="$1" pattern="$2" extra="$3"
	# NB: avoid the name `status` -- it is a read-only special variable in zsh
	# (an alias for $?), and assigning to it aborts the function mid-poll.
	local func_src remote_script params cmd_id inv_status out tries=0

	func_src="$(declare -f find_stuck_oom_processes)" || return 1
	remote_script="set -u
${func_src}
find_stuck_oom_processes ${extra} $(printf '%q' "$pattern")"
	params="$(jq -n --arg c "$remote_script" '{commands: [$c]}')"

	cmd_id="$(aws ssm send-command --instance-ids "$instance" \
		--document-name AWS-RunShellScript \
		--comment "find_stuck_oom_processes $pattern" \
		--parameters "$params" \
		--query 'Command.CommandId' --output text 2>/dev/null </dev/null)"
	[ -z "$cmd_id" ] || [ "$cmd_id" = "None" ] && {
		printf '(SSM send failed on %s)\n' "$instance"
		return 1
	}

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
	[ "$inv_status" = "Success" ]
}

# --- diagnostic: diagnose a set of tasks -------------------------------------
# Reads "<nativeId>\t<label>" lines on stdin (or takes native IDs as args),
# groups by EC2 instance, runs find_stuck_oom_processes on each.
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
	declare -F find_stuck_oom_processes >/dev/null 2>&1 || {
		printf 'Error: find_stuck_oom_processes not defined.\n' >&2
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
		printf '\n==> [%s] find_stuck_oom_processes "%s"\n' "$instance" "$pattern"
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
  aws_ssh_job_instance <job_id>
      Trace a Batch job to its EC2 instance and open an SSM session.

  find_stuck_oom_processes [--all|-a] [--match|-m TAG] PATTERN
      On-host check for processes stuck after child OOM kills.

  diagnose_oom_run ...
      Orchestrate run/workflow/task OOM diagnosis.

  help
      Show this help message.

Compatibility aliases:
  aws-ssh-job-instance, find-stuck-oom-processes, diagnose-oom-run
EOF
}

_xsh_main() {
	local entrypoint="${1:-}"

	case "$entrypoint" in
	"" | help | -h | --help)
		_xsh_usage
		[ -z "$entrypoint" ] && return 2 || return 0
		;;
	aws_ssh_job_instance | aws-ssh-job-instance)
		shift
		aws_ssh_job_instance "$@"
		;;
	find_stuck_oom_processes | find-stuck-oom-processes)
		shift
		find_stuck_oom_processes "$@"
		;;
	diagnose_oom_run | diagnose-oom-run)
		shift
		_dor_main "$@"
		;;
	*)
		printf 'x.sh: unknown command: %s\n\n' "$entrypoint" >&2
		_xsh_usage >&2
		return 2
		;;
	esac
}

# Source-compatible wrapper for existing users.
diagnose_oom_run() {
	_dor_main "$@"
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
	_xsh_main "$@"
	exit $?
fi
