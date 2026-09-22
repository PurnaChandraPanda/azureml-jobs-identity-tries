## Azure ML Identity Validation

This sample validates which Microsoft Entra identity is available to code running inside an Azure Machine Learning remote job.

The validation compares:

- Azure ML On-Behalf-Of authentication
- Azure ML compute managed identity authentication
- `user_identity` and `managed_identity` job configurations
- `AzureMLOnBehalfOfCredential` and `ManagedIdentityCredential`
- Signed-in user and managed identity submission paths
- Operating-system process identity and Microsoft Entra token identity
- Azure ML output persistence through the registered `workspaceblobstore` datastore

The primary remote compute target used by this sample is:

```text
cpu-cluster
```

# Pre-requisites

- Create a UAI for compute instance use.
- Grant UAI the `File Previleged Data Contributor` role on Storage account.
- Grant UAI the `Contributor` role on ml workspace.
- Create a compute instance with UAI mapped.
- Create another compute cluster with another UAI or SAI mapped.
- Set the `workspaceblobstore` datastore with auth type as None. This is a way to ensure caller ID is preferred to reach backend storage here.

# Prepare serverless computes infra

- Update the `serverlesscomputevnetsettings.yaml` if you are in vnet to allow serverless computes onboarding in user vnet.

```yaml
serverless_compute:
    # Supply subnet ARM ID where serverless computes should be created
    custom_subnet: /subscriptions/69-----------------------------------03/resourceGroups/vnets-rg/providers/Microsoft.Network/virtualNetworks/eus2vnet4324/subnets/default
    # Set true, if serverless computes should have just private IP
    # Set false, if serverless computes can have both public and private IP mapped
    no_public_ip: false
```

```bash
az account clear
az login --identity

az account set -s "69---------------------------------03"
az ml workspace update -n "mlws01" -g "rg-mlws" --file serverlesscomputevnetsettings.yaml
```

- For T7 flow testing, make sure UAI is mapped to current ML workspace. Same UAI is mapped to Compute Instance in this case. Grant UAI is given reader or contributor role on KV, and then try the `ml workspace update` command.

```bash
# set resource details <start>
SUBSCRIPTION_ID="69------------------03"
WORKSPACE_RG="rg-mlws"
WORKSPACE_NAME="mlws01"
UAMI_NAME="uai001"
# set resource details <end>

# Read UAI client id, and then append to existing ml workspace
UAMI_ID="$(
az identity show \
--name "$UAMI_NAME" \
--resource-group "$WORKSPACE_RG" \
--subscription "$SUBSCRIPTION_ID" \
--query id \
--output tsv
)"

az ml workspace show \
  --name "$WORKSPACE_NAME" \
  --resource-group "$WORKSPACE_RG" \
  --subscription "$SUBSCRIPTION_ID" \
  --query '{
    identity:identity,
    primaryUserAssignedIdentity:primary_user_assigned_identity
  }' \
  --output json \
  > workspace-identity-before.json

cat workspace-identity-before.json

cat > workspace-add-uami.yaml <<EOF
identity:
  type: system_assigned,user_assigned
  user_assigned_identities:
    "${UAMI_ID}": {}

primary_user_assigned_identity: "${UAMI_ID}"
EOF

cat workspace-add-uami.yaml

az ml workspace update \
  --name "$WORKSPACE_NAME" \
  --resource-group "$WORKSPACE_RG" \
  --subscription "$SUBSCRIPTION_ID" \
  --file workspace-add-uami.yaml \
  --primary-user-assigned-identity "$UAMI_ID" \
  --only-show-errors \
  --output json

# remove the generated files
rm -rf workspace-identity-before.json
rm -rf workspace-add-uami.yaml
```

# Register env

```bash
az login --identity

az ml environment create \
  --name "idenv" \
  --version "1" \
  --image "mcr.microsoft.com/azureml/openmpi5.0-ubuntu24.04:latest" \
  --conda-file "environment/conda.yaml" \
  --resource-group "rg-mlws" \
  --workspace-name "mlws01"
```

It will immediately start `register env -> build env`. Wait for the build to be over in some 20minutes and then start ML job runs.

# How to run jobs?

Update `run_tests.sh` user configuration values.

```
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
```

```bash

./run-tests.sh

# 1. Validate project, workspace, compute, datastore, and environment
./run_tests.sh preflight
```

```bash
az account clear
az login --identity
```

```bash
# 2. AML cluster + user_identity + AzureMLOnBehalfOfCredential
./run_tests.sh t1

# 3. AML cluster + managed_identity + AzureMLOnBehalfOfCredential
./run_tests.sh T4

# 4. AzureMLOnBehalfOfCredential inside a managed_identity job
./run_tests.sh T5

# 5. Serverless CPU + user_identity + AzureMLOnBehalfOfCredential
./run_tests.sh t6

# 6. Serverless managed identity test
./run_tests.sh T7

# 7. CI UAMI submits user_identity job, i.e. remote credential is OBO
./run_tests.sh T2

# 8. CI UAMI submits managed_identity job, i.e. remote credential is ManagedIdentityCredential
./run_tests.sh T3
```

# Validated identity and compute matrix

| Test   | Compute                    | Job `identity.type` | Credential inside job                                             | Submission principal                      | Expected result                                         | Your observed result       | Effective token principal                                                          |
| ------ | -------------------------- | ------------------- | ----------------------------------------------------------------- | ----------------------------------------- | ------------------------------------------------------- | -------------------------- | ---------------------------------------------------------------------------------- |
| **T1** | Named AML compute cluster  | `user_identity`     | `AzureMLOnBehalfOfCredential`                                     | Interactive user                          | **Works**                                               | **PASS**                   | Human user token, `idtyp=user`, `oid=140949e1...`, name and UPN present            |
| **T2** | Named AML compute cluster  | `user_identity`     | `AzureMLOnBehalfOfCredential`                                     | Compute Instance UAMI / service principal | **Works, but not as a human user**                      | **PASS**                   | Application token, `idtyp=app`, `oid=3974892c...`                                  |
| **T3** | Named AML compute cluster  | `managed_identity`  | `ManagedIdentityCredential`                                       | Compute Instance UAMI / service principal | **Works**                                               | **PASS**                   | AML compute identity, `appid=e4b0893f...`, `xms_mirid=.../computes/vnetcpucluster` |
| **T4** | Named AML compute cluster  | `user_identity`     | `ManagedIdentityCredential`                                       | Interactive user                          | **Works, but returns compute MI rather than submitter** | **PASS**                   | AML compute identity, identical to T3                                              |
| **T5** | Named AML compute cluster  | `managed_identity`  | `AzureMLOnBehalfOfCredential`                                     | Current CLI principal                     | **Does not work by design**                             | **Expected-negative PASS** | No token. OBO route returns HTTP 404                                               |
| **T6** | Serverless CPU command job | `user_identity`     | `AzureMLOnBehalfOfCredential`                                     | Interactive user                          | **Works**                                               | **PASS**                   | Human user token, same `oid=140949e1...` as T1                                     |
| **T7** | Serverless CPU command job | `managed_identity`  | `ManagedIdentityCredential(client_id=DEFAULT_ID..)` | Current CLI principal                     | **Works with workspace UAMI**                           | **PASS**                   | Workspace UAMI `uai001`, `appid=ec8a73d0...`, `oid=3974892c...`                    |


# General decision table

| Compute configuration                 | Job identity       | Credential to use                                              | Expected                               | Identity represented by token                                 |
| ------------------------------------- | ------------------ | -------------------------------------------------------------- | -------------------------------------- | ------------------------------------------------------------- |
| AML compute with MI                   | `user_identity`    | `AzureMLOnBehalfOfCredential`                                  | ✅ Supported                            | Submission principal                                          |
| AML compute with MI                   | `user_identity`    | `ManagedIdentityCredential`                                    | ✅ Supported                            | Compute managed identity                                      |
| AML compute with MI                   | `managed_identity` | `ManagedIdentityCredential`                                    | ✅ Supported                            | Compute managed identity                                      |
| AML compute with MI                   | `managed_identity` | `AzureMLOnBehalfOfCredential`                                  | ❌ Unsupported combination              | No token, because OBO is not enabled                          |
| Serverless CPU                        | `user_identity`    | `AzureMLOnBehalfOfCredential`                                  | ✅ Supported               | Submission principal                                          |
| Serverless CPU with workspace UAMI    | `managed_identity` | `ManagedIdentityCredential(client_id=...)`                     | ✅ Supported               | Workspace primary UAMI                                        |
| Serverless CPU with workspace UAMI    | `managed_identity` | Plain `ManagedIdentityCredential()`                            | ✅ Supported      | Workspace primary UAMI |
| Serverless CPU without workspace UAMI | `managed_identity` | `ManagedIdentityCredential`                                    | ❌ Not expected to work for this design | No suitable serverless runtime UAMI                           |



