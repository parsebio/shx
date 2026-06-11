#!/usr/bin/env bash

# Defines aws_ssh_job_instance(): given a Batch job ID, trace it
# through ECS to the underlying EC2 instance and open an SSM Session
# Manager session on it.
#
# Steps:
#   1. Look up the ECS container-instance ARN for the Batch job.
#   2. Look up the ECS cluster ARN for the job's compute environment.
#   3. Resolve the EC2 instance ID backing that container instance.
#   4. Start an SSM session on that EC2 instance.

aws_ssh_job_instance() {
	local usage
	read -r -d '' usage <<'EOF' || true
Usage: aws_ssh_job_instance [-h|--help] <job_id>

Trace a task's Native ID to its underlying EC2 instance and open
an SSM Session Manager session on it.

Arguments:
  batch_job_id  Batch job ID (AWS Batch executor)
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

	while [[ $# -gt 0 ]]; do
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
			if [[ -n "$job_id" ]]; then
				printf 'Error: too many arguments.\n\n' >&2
				printf '%s\n' "$usage" >&2
				return 1
			fi
			job_id="$1"
			;;
		esac
		shift
	done

	if [[ -z "$job_id" ]]; then
		printf 'Error: missing required argument <job_id>.\n\n' >&2
		printf '%s\n' "$usage" >&2
		return 1
	fi

	# --- Helper: fail if a resolved value is empty/None -----------------------

	local require_value
	require_value() {
		local value="$1" label="$2"
		if [[ -z "$value" || "$value" == "None" ]]; then
			printf 'Error: could not resolve %s.\n' "$label" >&2
			return 1
		fi
	}

	# --- Trace the job --------------------------------------------------------

	local container_instance_arn job_queue_arn compute_env ecs_cluster_arn ec2_instance_id

	printf '==> Looking up container-instance ARN for Batch job: %s\n' "$job_id"
	container_instance_arn="$(aws batch describe-jobs \
		--jobs "$job_id" \
		--query 'jobs[0].container.containerInstanceArn' \
		--output text)" || return 1
	require_value "$container_instance_arn" "container-instance ARN" || return 1
	printf '    %s\n' "$container_instance_arn"

	printf '==> Looking up compute environment for Batch job: %s\n' "$job_id"
	job_queue_arn="$(aws batch describe-jobs \
		--jobs "$job_id" \
		--query 'jobs[0].jobQueue' \
		--output text)" || return 1
	require_value "$job_queue_arn" "job queue" || return 1

	compute_env="$(aws batch describe-job-queues \
		--job-queues "$job_queue_arn" \
		--query 'jobQueues[0].computeEnvironmentOrder[0].computeEnvironment' \
		--output text)" || return 1
	require_value "$compute_env" "compute environment" || return 1
	printf '    %s\n' "$compute_env"

	printf '==> Looking up ECS cluster ARN for compute environment\n'
	ecs_cluster_arn="$(aws batch describe-compute-environments \
		--compute-environments "$compute_env" \
		--query 'computeEnvironments[0].ecsClusterArn' \
		--output text)" || return 1
	require_value "$ecs_cluster_arn" "ECS cluster ARN" || return 1
	printf '    %s\n' "$ecs_cluster_arn"

	printf '==> Resolving EC2 instance ID for container instance\n'
	ec2_instance_id="$(aws ecs describe-container-instances \
		--cluster "$ecs_cluster_arn" \
		--container-instances "$container_instance_arn" \
		--query 'containerInstances[0].ec2InstanceId' \
		--output text)" || return 1
	require_value "$ec2_instance_id" "EC2 instance ID" || return 1
	printf '    %s\n' "$ec2_instance_id"

	# --- Connect --------------------------------------------------------------

	printf '==> Starting SSM session on %s\n' "$ec2_instance_id"
	aws ssm start-session --target "$ec2_instance_id"
}

# -----------------------------------------------------------------------------
# Find processes that are hung because the kernel OOM-killed some of their
# children but NOT the process itself, leaving the parent deadlocked.
#
# Run this ON THE HOST. A single host can run several instances of the same
# program at once, each in its own memory cgroup. This script walks EVERY
# process matching a pattern, prints its cgroup + memory facts, and flags the
# ones that are stuck (OOM-killed children + zombie/defunct child processes).
#
# What "stuck" looks like (cgroup v2):
#   - memory.events shows  oom_kill > 0      -> kernel killed processes here
#   - memory.events shows  oom_group_kill 0  -> the cgroup was NOT killed as a
#                                               unit, so the parent survived
#                                               and hung instead of failing
#   - the parent has zombie (Z / defunct) children it can never reap
#
# memory.oom.group (0 = default) controls the "kill as a unit" behaviour.
# Reading it just confirms the mechanism.
#
# Usage:
#   bash diagnose-cgroup-oom.sh PATTERN                  # print only STUCK matches
#   bash diagnose-cgroup-oom.sh --all PATTERN            # print every match
#   bash diagnose-cgroup-oom.sh -m TAG PATTERN           # filter matches by cmdline
#   source diagnose-cgroup-oom.sh                        # load the function, then:
#   find_stuck_oom_processes [--all] [-m TAG] PATTERN
#
# PATTERN is a 'pgrep -f' pattern selecting the process(es) to inspect (e.g. a
# program name). It may also be supplied via the PROC_PATTERN env var.
#
# By default only STUCK matches are printed. Pass --all (or -a) to print every
# match regardless of verdict. Pass --match/-m TAG to consider only matches
# whose command line contains TAG; TAG is matched case-sensitively.
#
# Tunables (env vars):
#   CGROUP_ROOT   cgroup v2 unified mount point (default: /sys/fs/cgroup)
#   PROC_PATTERN  default process pattern if none is given on the command line
# -----------------------------------------------------------------------------

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
