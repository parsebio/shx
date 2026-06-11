# Defines ssh_job_instance(): given a Batch job ID, trace it
# through ECS to the underlying EC2 instance and open an SSM Session
# Manager session on it.
#
# Source this file to load the function into your shell:
#   source ssm-connect.sh
#   ssh_job_instance aa00a1e2-1e96-4cbb-a670-3b33c5ac356d
#
# Steps:
#   1. Look up the ECS container-instance ARN for the Batch job.
#   2. Look up the ECS cluster ARN for the job's compute environment.
#   3. Resolve the EC2 instance ID backing that container instance.
#   4. Start an SSM session on that EC2 instance.

ssh_job_instance() {
	local usage
	read -r -d '' usage <<'EOF' || true
Usage: ssh_job_instance [-h|--help] <job_id>

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
  ssh_job_instance aa00a1e2-1e96-4cbb-a670-3b33c5ac356d
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
