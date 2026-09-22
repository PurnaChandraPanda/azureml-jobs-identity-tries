#!/usr/bin/env bash

set -euo pipefail

# =============================================================================
# USER CONFIGURATION
# =============================================================================

AZURE_SUBSCRIPTION_ID="69--------------------------------03"
AZURE_RESOURCE_GROUP="rg-mlws"
AZUREML_WORKSPACE_NAME="mlws01"

# Remote Azure ML compute cluster used by T1 through T5.
COMPUTE_CLUSTER="vnetcpucluster"

# Client ID of the UAMI attached to the Compute Instance.
# T2 and T3 switch the Azure CLI session to this UAMI.
CI_UAI_CLIENT_ID="ec-----------------------------------8c"

# Workspace environment referenced by both job YAML files.
AML_ENVIRONMENT_NAME="idenv"
AML_ENVIRONMENT_VERSION="1"

# AML compute-cluster command job used by T1 through T5.
BASE_YAML="job.yaml"

# Serverless CPU command job used by T6 and T7.
#
# This YAML must not contain a compute property.
# Omitting compute causes Azure ML to select serverless compute.
SERVERLESS_YAML="job-serverless.yaml"

# Local directory for submission logs, job names, and status files.
RESULTS_DIR="submitted-jobs"

# Job polling configuration.
POLL_INTERVAL_SECONDS=20
MAX_POLL_ATTEMPTS=180

# =============================================================================
# INITIALIZATION
# =============================================================================

mkdir -p "$RESULTS_DIR"

# =============================================================================
# IDENTITY HELPERS
# =============================================================================

describe_submitter() {
    local principal_type

    principal_type="$(
        az account show \
            --query "user.type" \
            --output tsv 2>/dev/null || true
    )"

    echo
    echo "Submission principal:"
    echo

    az account show \
        --query '{
            subscriptionName: name,
            subscriptionId: id,
            tenantId: tenantId,
            user: user
        }' \
        --output json

    echo
    echo "Azure CLI principal type: ${principal_type:-unknown}"
    echo
    echo "Signed-in user lookup:"
    echo

    if az ad signed-in-user show \
        --query '{
            displayName: displayName,
            userPrincipalName: userPrincipalName,
            objectId: id
        }' \
        --output json 2>/dev/null; then

        echo
        echo "Azure CLI session resolves to a signed-in user."
        return 0
    fi

    echo "No signed-in user object was returned."
    echo "The Azure CLI session is using a managed identity or service principal."
    echo "Use the remote token claims to determine the effective identity."

    return 1
}

require_submission_principal() {
    local principal_type

    principal_type="$(
        az account show \
            --query "user.type" \
            --output tsv 2>/dev/null \
        | tr '[:upper:]' '[:lower:]' \
        || true
    )"

    case "$principal_type" in
        user)
            echo
            echo "Azure CLI is authenticated as an interactive user."
            echo "A user_identity job is expected to return a user token."
            ;;

        serviceprincipal)
            echo
            echo "Azure CLI is authenticated as a service principal or managed identity."
            echo "A user_identity job may return an application token instead of a human-user token."
            echo "Validate the token using appid, oid, idtyp, and xms_mirid claims."
            ;;

        *)
            echo
            echo "ERROR: Unsupported or unknown Azure CLI principal type."
            echo "Current principal type: ${principal_type:-unknown}"
            return 1
            ;;
    esac

    describe_submitter || true
}


login_ci_uai() {
    : "${CI_UAI_CLIENT_ID:?Set CI_UAI_CLIENT_ID before running T2 or T3}"

    echo
    echo "Switching Azure CLI authentication to the Compute Instance UAMI..."
    echo

    az account clear

    az login \
        --identity \
        --client-id "$CI_UAI_CLIENT_ID" \
        --allow-no-subscriptions \
        --output none

    az account set \
        --subscription "$AZURE_SUBSCRIPTION_ID"

    describe_submitter || true
}

# =============================================================================
# PREFLIGHT VALIDATION
# =============================================================================

preflight() {
    local requested_scope="${1:-base}"

    echo
    echo "============================================================"
    echo "Running preflight checks"
    echo "============================================================"

    if ! command -v az >/dev/null 2>&1; then
        echo "ERROR: Azure CLI is not installed or is not in PATH."
        return 1
    fi

    if ! az extension show --name ml >/dev/null 2>&1; then
        echo "ERROR: Azure ML CLI extension is not installed."
        echo
        echo "Install it with:"
        echo "  az extension add --name ml --yes"
        return 1
    fi

    if [[ ! -f "$BASE_YAML" ]]; then
        echo "ERROR: Azure ML job YAML was not found: $BASE_YAML"
        return 1
    fi

    if [[ ! -f "src/identity_probe.py" ]]; then
        echo "ERROR: Python probe was not found: src/identity_probe.py"
        return 1
    fi

    case "$requested_scope" in
        T6|t6|T7|t7|serverless|all)
            if [[ ! -f "$SERVERLESS_YAML" ]]; then
                echo "ERROR: Serverless job YAML was not found: $SERVERLESS_YAML"
                return 1
            fi

            echo "Checking serverless YAML does not declare compute..."

            if grep -Eq \
                '^[[:space:]]*compute[[:space:]]*:' \
                "$SERVERLESS_YAML"; then

                echo "ERROR: $SERVERLESS_YAML contains a compute property."
                echo "For a serverless CPU command job, omit the compute property."
                return 1
            fi
            ;;
    esac

    echo "Checking shell syntax..."
    bash -n "$0"

    echo "Checking Python syntax..."
    python -m py_compile src/identity_probe.py

    echo "Checking Azure subscription..."
    az account set \
        --subscription "$AZURE_SUBSCRIPTION_ID"

    echo "Configuring Azure CLI defaults..."
    az configure --defaults \
        group="$AZURE_RESOURCE_GROUP" \
        workspace="$AZUREML_WORKSPACE_NAME"

    echo "Checking Azure ML workspace..."
    az ml workspace show \
        --resource-group "$AZURE_RESOURCE_GROUP" \
        --name "$AZUREML_WORKSPACE_NAME" \
        --only-show-errors \
        --output none

    echo "Checking Azure ML compute cluster..."
    az ml compute show \
        --resource-group "$AZURE_RESOURCE_GROUP" \
        --workspace-name "$AZUREML_WORKSPACE_NAME" \
        --name "$COMPUTE_CLUSTER" \
        --only-show-errors \
        --output none

    echo "Checking workspaceblobstore..."
    az ml datastore show \
        --resource-group "$AZURE_RESOURCE_GROUP" \
        --workspace-name "$AZUREML_WORKSPACE_NAME" \
        --name "workspaceblobstore" \
        --only-show-errors \
        --output none

    echo "Checking Azure ML environment..."
    az ml environment show \
        --resource-group "$AZURE_RESOURCE_GROUP" \
        --workspace-name "$AZUREML_WORKSPACE_NAME" \
        --name "$AML_ENVIRONMENT_NAME" \
        --version "$AML_ENVIRONMENT_VERSION" \
        --only-show-errors \
        --output none

    echo
    echo "Preflight checks passed."
}

# =============================================================================
# JOB MONITORING
# =============================================================================

wait_for_job() {
    local job_name="$1"
    local test_id="$2"

    local status="Unknown"
    local status_file
    local attempt=0

    status_file="$RESULTS_DIR/${test_id}.remote-status.txt"

    echo
    echo "Monitoring remote Azure ML job: $job_name"
    echo

    while true; do
        attempt=$((attempt + 1))

        if (( attempt > MAX_POLL_ATTEMPTS )); then
            echo "TimedOut" > "$status_file"

            echo
            echo "ERROR: Maximum polling attempts exceeded."
            echo "Last observed status: $status"

            return 1
        fi

        status="$(
            az ml job show \
                --name "$job_name" \
                --resource-group "$AZURE_RESOURCE_GROUP" \
                --workspace-name "$AZUREML_WORKSPACE_NAME" \
                --query "status" \
                --output tsv \
                --only-show-errors 2>/dev/null || true
        )"

        status="${status:-Unknown}"

        echo "Remote status: $status"

        case "$status" in
            Completed)
                echo "$status" > "$status_file"
                return 0
                ;;

            Failed|Canceled|CancelRequested|NotResponding)
                echo "$status" > "$status_file"
                return 1
                ;;

            Queued|NotStarted|Starting|Preparing|Provisioning|Running|Finalizing)
                sleep "$POLL_INTERVAL_SECONDS"
                ;;

            Unknown|"")
                echo "The job status could not be retrieved. Retrying..."
                sleep "$POLL_INTERVAL_SECONDS"
                ;;

            *)
                echo "Unrecognized Azure ML job status: $status"
                sleep "$POLL_INTERVAL_SECONDS"
                ;;
        esac
    done
}

show_job_summary() {
    local job_name="$1"

    echo
    echo "Final Azure ML job summary:"
    echo

    az ml job show \
        --name "$job_name" \
        --resource-group "$AZURE_RESOURCE_GROUP" \
        --workspace-name "$AZUREML_WORKSPACE_NAME" \
        --query '{
            name: name,
            displayName: display_name,
            status: status,
            compute: compute,
            identity: identity,
            environment: environment
        }' \
        --output json \
        --only-show-errors
}

print_log_command() {
    local job_name="$1"

    echo
    echo "Stream the remote logs with:"
    echo

    printf \
        'az ml job stream --name %q --resource-group %q --workspace-name %q\n' \
        "$job_name" \
        "$AZURE_RESOURCE_GROUP" \
        "$AZUREML_WORKSPACE_NAME"
}

# =============================================================================
# COMMON JOB SUBMISSION
# =============================================================================

submit_job() {
    local yaml_file="$1"
    local test_id="$2"
    local identity_type="$3"
    local credential_mode="$4"
    local expected="$5"
    local expect_token_failure="${6:-false}"
    # Empty for serverless jobs.
    local compute_name="${7:-}"

    local job_name
    local submission_log
    local submission_rc
    local remote_rc=1

    job_name="identity-${test_id,,}-$(date -u +%Y%m%d%H%M%S)"
    submission_log="$RESULTS_DIR/${test_id}.submission.log"

    echo
    echo "============================================================"
    echo "$test_id: Azure ML identity validation"
    echo "============================================================"
    echo "Job YAML       : $yaml_file"
    echo "Job identity   : $identity_type"
    echo "Credential     : $credential_mode"
    echo "Compute        : ${compute_name:-serverless, selected by Azure ML}"
    echo "Expected result: $expected"
    echo "Job name       : $job_name"
    echo

    local args=(
        az ml job create
        --file "$yaml_file"
        --name "$job_name"
        --set "display_name=$job_name"
        --set "identity.type=$identity_type"
        --set "inputs.test_id=$test_id"
        --set "inputs.credential_mode=$credential_mode"
        --set "inputs.expect_token_failure=$expect_token_failure"
        --resource-group "$AZURE_RESOURCE_GROUP"
        --workspace-name "$AZUREML_WORKSPACE_NAME"
        --only-show-errors
        --output json
    )

    # Add a compute override only for T1 through T5.
    # For T6 and T7, compute_name is empty, so Azure ML selects serverless.
    if [[ -n "$compute_name" ]]; then
        args+=(--set "compute=azureml:$compute_name")
    fi

    printf "Command:"
    printf " %q" "${args[@]}"
    printf "\n\n"

    echo "$job_name" \
        > "$RESULTS_DIR/${test_id}.job-name.txt"

    set +e

    "${args[@]}" 2>&1 |
        tee "$submission_log"

    submission_rc=${PIPESTATUS[0]}

    set -e

    echo "$submission_rc" \
        > "$RESULTS_DIR/${test_id}.submission-exit-code.txt"

    if [[ "$submission_rc" -ne 0 ]]; then
        echo
        echo "ERROR: $test_id job submission failed."
        echo "Review: $submission_log"

        return "$submission_rc"
    fi

    echo
    echo "Job submission succeeded."

    set +e

    wait_for_job \
        "$job_name" \
        "$test_id"

    remote_rc=$?

    set -e

    echo "$remote_rc" \
        > "$RESULTS_DIR/${test_id}.remote-exit-code.txt"

    show_job_summary "$job_name" || true

    if [[ "$remote_rc" -ne 0 ]]; then
        echo
        echo "ERROR: $test_id remote Azure ML job failed."

        print_log_command "$job_name"

        return "$remote_rc"
    fi

    echo
    echo "PASS: $test_id remote Azure ML job completed."
    echo
    echo "Result files:"
    echo "  Job name       : $RESULTS_DIR/${test_id}.job-name.txt"
    echo "  Submission log : $submission_log"
    echo "  Submission RC  : $RESULTS_DIR/${test_id}.submission-exit-code.txt"
    echo "  Remote status  : $RESULTS_DIR/${test_id}.remote-status.txt"
    echo "  Remote RC      : $RESULTS_DIR/${test_id}.remote-exit-code.txt"
}

# =============================================================================
# TEST DEFINITIONS
# =============================================================================

run_one() {
    local test_id="${1^^}"

    case "$test_id" in
        T1)
            require_submission_principal

            submit_job \
                "$BASE_YAML" \
                "T1" \
                "user_identity" \
                "obo" \
                "Record the effective caller identity. Expect idtyp=user for interactive submission or idtyp=app for managed-identity submission." \
                "false" \
                "$COMPUTE_CLUSTER"
            ;;

        T2)
            login_ci_uai

            submit_job \
                "$BASE_YAML" \
                "T2" \
                "user_identity" \
                "obo" \
                "Observe the token returned when a Compute Instance UAMI submits a user_identity job." \
                "false" \
                "$COMPUTE_CLUSTER"
            ;;

        T3)
            login_ci_uai

            submit_job \
                "$BASE_YAML" \
                "T3" \
                "managed_identity" \
                "managed" \
                "ManagedIdentityCredential should expose the runtime-selected managed identity." \
                "false" \
                "$COMPUTE_CLUSTER"
            ;;

        T4)
            require_submission_principal

            submit_job \
                "$BASE_YAML" \
                "T4" \
                "user_identity" \
                "managed" \
                "Determine whether ManagedIdentityCredential is available in a user_identity job." \
                "false" \
                "$COMPUTE_CLUSTER"
            ;;

        T5)
            require_submission_principal

            submit_job \
                "$BASE_YAML" \
                "T5" \
                "managed_identity" \
                "obo" \
                "Expected negative test: OBO token acquisition should be unavailable in a managed_identity job." \
                "true" \
                "$COMPUTE_CLUSTER"
            ;;

        T6)
            require_submission_principal

            # No compute argument is supplied.
            submit_job \
                "$SERVERLESS_YAML" \
                "T6" \
                "user_identity" \
                "obo" \
                "Record the serverless caller identity. Expect idtyp=user for interactive submission or idtyp=app for managed-identity submission." \
                "false"
            ;;

        T7)
            describe_submitter || true

            # No compute argument is supplied.
            submit_job \
                "$SERVERLESS_YAML" \
                "T7" \
                "managed_identity" \
                "managed" \
                "Serverless ManagedIdentityCredential should resolve the workspace UAMI." \
                "false"
            ;;

        *)
            echo "Unknown test: $test_id" >&2
            return 64
            ;;
    esac
}

run_test_set() {
    local failed=0
    local test_id

    for test_id in "$@"; do
        if ! run_one "$test_id"; then
            echo
            echo "FAILED: $test_id"
            failed=1
        fi
    done

    return "$failed"
}

print_usage() {
    echo "Usage:"
    echo "  $0 preflight"
    echo "  $0 T1"
    echo "  $0 T2"
    echo "  $0 T3"
    echo "  $0 T4"
    echo "  $0 T5"
    echo "  $0 T6"
    echo "  $0 T7"
    echo "  $0 cluster"
    echo "  $0 serverless"
    echo "  $0 all"
    echo
    echo "Notes:"
    echo "  T1, T4, T5, and T6 require an interactive Azure CLI user."
    echo "  T2 and T3 switch Azure CLI authentication to CI_UAI_CLIENT_ID."
    echo "  T6 and T7 use job-serverless.yaml without a compute property."
}

# =============================================================================
# COMMAND-LINE ENTRY POINT
# =============================================================================

case "${1:-}" in
    preflight)
        preflight "base"
        ;;

    T1|t1|T2|t2|T3|t3|T4|t4|T5|t5|T6|t6|T7|t7)
        preflight "$1"
        run_one "$1"
        ;;

    cluster)
        preflight "cluster"

        # Run user-session tests before T2 switches Azure CLI to the CI UAMI.
        run_test_set \
            T1 \
            T4 \
            T5 \
            T2 \
            T3
        ;;

    serverless)
        preflight "serverless"

        run_test_set \
            T6 \
            T7
        ;;

    all)
        preflight "all"

        # Run user-session tests before T2 switches Azure CLI to the CI UAMI.
        run_test_set \
            T1 \
            T4 \
            T5 \
            T6 \
            T7 \
            T2 \
            T3
        ;;

    *)
        print_usage >&2
        exit 64
        ;;
esac