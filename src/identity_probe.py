#!/usr/bin/env python3

"""
Azure Machine Learning identity validation probe.

Supported credential modes:

1. obo
   Uses AzureMLOnBehalfOfCredential.

2. managed
   Uses ManagedIdentityCredential.

The probe requests tokens for:

- Azure Resource Manager
- Azure Storage

The JWT payload is decoded only for diagnostics. The token signature is not
validated by this script.

Output files:

- <test-id>-identity-report.json
- <test-id>-identity-summary.json
- <test-id>-data.txt

When --expect-token-failure is true, the probe returns exit code 0 only when
all requested token acquisitions fail. This supports negative scenarios such
as T5.
"""

from __future__ import annotations

import argparse
import base64
import json
import os
import platform
import pwd
import socket
import sys
import traceback
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

from azure.ai.ml.identity import AzureMLOnBehalfOfCredential
from azure.identity import ManagedIdentityCredential


TOKEN_SCOPES = {
    "arm": "https://management.azure.com/.default",
    "storage": "https://storage.azure.com/.default",
}


ENVIRONMENT_VARIABLES = [
    "AZUREML_ARM_RESOURCEGROUP",
    "AZUREML_ARM_SUBSCRIPTION",
    "AZUREML_ARM_WORKSPACE_NAME",
    "AZUREML_CR_COMPUTE_TYPE",
    "AZUREML_OBO_ENABLED",
    "AZUREML_RUN_ID",
    "DEFAULT_IDENTITY_CLIENT_ID",
    "IDENTITY_ENDPOINT",
    "IMDS_ENDPOINT",
    "MLFLOW_RUN_ID",
    "MSI_ENDPOINT",
    "OBO_ENDPOINT",
]


JWT_CLAIMS_TO_CAPTURE = [
    "appid",
    "aud",
    "azp",
    "idtyp",
    "iss",
    "name",
    "oid",
    "preferred_username",
    "sub",
    "tid",
    "unique_name",
    "upn",
    "xms_mirid",
]


def parse_boolean(value: str | bool) -> bool:
    """Convert a command-line value to boolean."""

    if isinstance(value, bool):
        return value

    normalized = value.strip().lower()

    if normalized in {"true", "1", "yes", "y", "on"}:
        return True

    if normalized in {"false", "0", "no", "n", "off"}:
        return False

    raise argparse.ArgumentTypeError(
        f"Invalid boolean value: {value!r}. "
        "Use true/false, 1/0, yes/no, or on/off."
    )


def utc_now() -> datetime:
    """Return the current UTC time."""

    return datetime.now(timezone.utc)


def utc_timestamp_for_path() -> str:
    """Return a compact UTC timestamp suitable for folder names."""

    return utc_now().strftime("%Y%m%dT%H%M%SZ")


def utc_isoformat() -> str:
    """Return the current UTC timestamp in ISO 8601 format."""

    return utc_now().isoformat()


def decode_base64url(value: str) -> bytes:
    """Decode a Base64 URL-safe string."""

    padding = "=" * (-len(value) % 4)
    return base64.urlsafe_b64decode((value + padding).encode("ascii"))


def decode_jwt_payload(token: str) -> dict[str, Any]:
    """
    Decode the JWT payload without validating the signature.

    This function is for diagnostics only.
    """

    token_parts = token.split(".")

    if len(token_parts) < 2:
        raise ValueError("Access token is not in JWT format.")

    payload_bytes = decode_base64url(token_parts[1])
    payload = json.loads(payload_bytes.decode("utf-8"))

    if not isinstance(payload, dict):
        raise ValueError("JWT payload is not a JSON object.")

    return payload


def select_jwt_claims(payload: dict[str, Any]) -> dict[str, Any]:
    """Return only the claims relevant to identity diagnostics."""

    return {
        claim_name: payload[claim_name]
        for claim_name in JWT_CLAIMS_TO_CAPTURE
        if claim_name in payload
    }


def access_token_expiry_to_utc(expires_on: int) -> str:
    """Convert the token expiry epoch to UTC ISO format."""

    return datetime.fromtimestamp(
        expires_on,
        tz=timezone.utc,
    ).isoformat()


def current_os_user() -> str:
    """Return the operating-system user running the process."""

    try:
        return pwd.getpwuid(os.getuid()).pw_name
    except Exception:
        return os.environ.get("USER", "unknown")


def collect_process_information() -> dict[str, Any]:
    """Collect process and host information."""

    process_information: dict[str, Any] = {
        "hostname": socket.gethostname(),
        "os_user": current_os_user(),
        "platform": platform.platform(),
        "python_version": sys.version,
    }

    if hasattr(os, "getuid"):
        process_information["uid"] = os.getuid()

    if hasattr(os, "getgid"):
        process_information["gid"] = os.getgid()

    return process_information


def collect_azureml_environment() -> dict[str, str | None]:
    """Collect selected Azure ML runtime environment variables."""

    return {
        variable_name: os.environ.get(variable_name)
        for variable_name in ENVIRONMENT_VARIABLES
    }


def create_credential(
    credential_mode: str,
    managed_identity_client_id: str | None,
) -> tuple[Any, str]:
    """Create the credential selected by the test."""

    if credential_mode == "obo":
        credential = AzureMLOnBehalfOfCredential()
        credential_class = "AzureMLOnBehalfOfCredential"
        return credential, credential_class
    
    elif credential_mode == "managed":
        effective_client_id = (
            managed_identity_client_id
            or os.environ.get("DEFAULT_IDENTITY_CLIENT_ID")
        )

        if effective_client_id:
            credential = ManagedIdentityCredential(
                client_id=effective_client_id
            )
            credential_class = (
                "ManagedIdentityCredential "
                f"(client_id={effective_client_id})"
            )
        else:
            credential = ManagedIdentityCredential()
            credential_class = (
                "ManagedIdentityCredential "
                "(default runtime identity)"
            )

        return credential, credential_class

    raise ValueError(
        f"Unsupported credential mode: {credential_mode!r}"
    )


def close_credential(credential: Any) -> None:
    """Close the credential transport if the credential exposes close()."""

    close_method = getattr(credential, "close", None)

    if callable(close_method):
        try:
            close_method()
        except Exception as exc:
            print(
                f"Credential close warning: "
                f"{type(exc).__name__}: {exc}",
                file=sys.stderr,
            )


def acquire_token_claims(
    credential: Any,
    scope: str,
) -> dict[str, Any]:
    """Acquire one token and return diagnostic claims."""

    try:
        access_token = credential.get_token(scope)
        payload = decode_jwt_payload(access_token.token)

        result = {
            "success": True,
            "scope": scope,
            "expires_on_utc": access_token_expiry_to_utc(
                access_token.expires_on
            ),
            "claims": select_jwt_claims(payload),
        }

        print(
            f"Token acquisition succeeded for scope: {scope}",
            file=sys.stderr,
        )

        return result

    except Exception as exc:
        error_result = {
            "success": False,
            "scope": scope,
            "error_type": type(exc).__name__,
            "error": str(exc),
            "traceback": traceback.format_exc(),
        }

        print(
            f"Token acquisition failed for scope: {scope}",
            file=sys.stderr,
        )
        print(
            f"{type(exc).__name__}: {exc}",
            file=sys.stderr,
        )

        return error_result


def write_json(path: Path, content: dict[str, Any]) -> None:
    """Write a dictionary as formatted JSON."""

    path.parent.mkdir(parents=True, exist_ok=True)

    with path.open(
        "w",
        encoding="utf-8",
    ) as output_file:
        json.dump(
            content,
            output_file,
            indent=2,
            sort_keys=True,
            ensure_ascii=False,
        )
        output_file.write("\n")


def write_text(path: Path, content: str) -> None:
    """Write a UTF-8 text file."""

    path.parent.mkdir(parents=True, exist_ok=True)

    with path.open(
        "w",
        encoding="utf-8",
    ) as output_file:
        output_file.write(content)

        if not content.endswith("\n"):
            output_file.write("\n")


def build_identity_summary(
    report: dict[str, Any],
) -> dict[str, Any]:
    """Create a compact identity summary from the full report."""

    token_summary: dict[str, Any] = {}

    token_checks = report.get("token_checks", {})

    for token_name, token_result in token_checks.items():
        if token_result.get("success"):
            claims = token_result.get("claims", {})

            token_summary[token_name] = {
                "success": True,
                "scope": token_result.get("scope"),
                "expires_on_utc": token_result.get(
                    "expires_on_utc"
                ),
                "aud": claims.get("aud"),
                "idtyp": claims.get("idtyp"),
                "appid": claims.get("appid"),
                "azp": claims.get("azp"),
                "oid": claims.get("oid"),
                "sub": claims.get("sub"),
                "tid": claims.get("tid"),
                "name": claims.get("name"),
                "preferred_username": claims.get(
                    "preferred_username"
                ),
                "unique_name": claims.get("unique_name"),
                "upn": claims.get("upn"),
                "xms_mirid": claims.get("xms_mirid"),
            }
        else:
            token_summary[token_name] = {
                "success": False,
                "scope": token_result.get("scope"),
                "error_type": token_result.get("error_type"),
                "error": token_result.get("error"),
            }

    return {
        "test_id": report.get("test_id"),
        "timestamp_utc": report.get("timestamp_utc"),
        "credential_mode_requested": report.get(
            "credential_mode_requested"
        ),
        "credential_class": report.get("credential_class"),
        "managed_identity_client_id_requested": report.get(
            "managed_identity_client_id_requested"
        ),
        "expect_token_failure": report.get(
            "expect_token_failure"
        ),
        "expected_result": report.get("expected_result"),
        "token_checks": token_summary,
        "azureml_environment": report.get(
            "azureml_environment"
        ),
        "process": report.get("process"),
    }


def build_data_file_content(
    report: dict[str, Any],
) -> str:
    """Create the plain-text diagnostic file."""

    lines = [
        f"test_id={report.get('test_id')}",
        f"timestamp_utc={report.get('timestamp_utc')}",
        (
            "credential_mode_requested="
            f"{report.get('credential_mode_requested')}"
        ),
        f"credential_class={report.get('credential_class')}",
        (
            "managed_identity_client_id_requested="
            f"{report.get('managed_identity_client_id_requested')}"
        ),
        (
            "expect_token_failure="
            f"{report.get('expect_token_failure')}"
        ),
        (
            "expected_result_passed="
            f"{report.get('expected_result', {}).get('passed')}"
        ),
    ]

    token_checks = report.get("token_checks", {})

    for token_name, token_result in token_checks.items():
        lines.append(
            f"{token_name}_token_success="
            f"{token_result.get('success')}"
        )

        if token_result.get("success"):
            claims = token_result.get("claims", {})

            lines.extend(
                [
                    (
                        f"{token_name}_token_aud="
                        f"{claims.get('aud')}"
                    ),
                    (
                        f"{token_name}_token_idtyp="
                        f"{claims.get('idtyp')}"
                    ),
                    (
                        f"{token_name}_token_appid="
                        f"{claims.get('appid')}"
                    ),
                    (
                        f"{token_name}_token_oid="
                        f"{claims.get('oid')}"
                    ),
                    (
                        f"{token_name}_token_tid="
                        f"{claims.get('tid')}"
                    ),
                    (
                        f"{token_name}_token_name="
                        f"{claims.get('name')}"
                    ),
                    (
                        f"{token_name}_token_username="
                        f"{claims.get('preferred_username') or claims.get('unique_name') or claims.get('upn')}"
                    ),
                    (
                        f"{token_name}_token_xms_mirid="
                        f"{claims.get('xms_mirid')}"
                    ),
                ]
            )
        else:
            lines.extend(
                [
                    (
                        f"{token_name}_token_error_type="
                        f"{token_result.get('error_type')}"
                    ),
                    (
                        f"{token_name}_token_error="
                        f"{token_result.get('error')}"
                    ),
                ]
            )

    return "\n".join(lines)


def parse_arguments() -> argparse.Namespace:
    """Parse command-line arguments."""

    parser = argparse.ArgumentParser(
        description=(
            "Validate Azure ML user and managed identity "
            "token behavior."
        )
    )

    parser.add_argument(
        "--test-id",
        required=True,
        help="Test identifier, for example T1, T3, or T6.",
    )

    parser.add_argument(
        "--credential-mode",
        required=True,
        choices=["obo", "managed"],
        help=(
            "Credential implementation to test: "
            "AzureMLOnBehalfOfCredential or "
            "ManagedIdentityCredential."
        ),
    )

    parser.add_argument(
        "--managed-identity-client-id",
        default=None,
        help=(
            "Optional UAMI client ID supplied explicitly to "
            "ManagedIdentityCredential."
        ),
    )

    parser.add_argument(
        "--expect-token-failure",
        type=parse_boolean,
        default=False,
        help=(
            "When true, the test passes only when all token "
            "requests fail."
        ),
    )

    parser.add_argument(
        "--output-dir",
        required=True,
        help=(
            "Azure ML output directory supplied through "
            "${{outputs.identity_report}}."
        ),
    )

    return parser.parse_args()


def evaluate_expected_result(
    token_checks: dict[str, dict[str, Any]],
    expect_token_failure: bool,
) -> tuple[dict[str, Any], int]:
    """
    Evaluate the token results.

    Returns:
        Tuple of expected-result details and process exit code.
    """

    total_checks = len(token_checks)

    successful_checks = sum(
        1
        for token_result in token_checks.values()
        if token_result.get("success") is True
    )

    failed_checks = total_checks - successful_checks

    if expect_token_failure:
        passed = (
            total_checks > 0
            and successful_checks == 0
        )

        result = {
            "expect_token_failure": True,
            "passed": passed,
            "total_token_checks": total_checks,
            "successful_token_checks": successful_checks,
            "failed_token_checks": failed_checks,
            "message": (
                "All token requests failed as expected."
                if passed
                else (
                    "At least one token request unexpectedly "
                    "succeeded."
                )
            ),
        }

        return result, 0 if passed else 3

    passed = (
        total_checks > 0
        and successful_checks == total_checks
    )

    result = {
        "expect_token_failure": False,
        "passed": passed,
        "total_token_checks": total_checks,
        "successful_token_checks": successful_checks,
        "failed_token_checks": failed_checks,
        "message": (
            "All token requests succeeded."
            if passed
            else "One or more token requests failed."
        ),
    }

    return result, 0 if passed else 2


def main() -> int:
    """Run the identity validation probe."""

    args = parse_arguments()

    test_id = args.test_id.upper()
    output_root = Path(args.output_dir).resolve()
    test_output_directory = (
        output_root
        / test_id
        / utc_timestamp_for_path()
    )

    test_output_directory.mkdir(
        parents=True,
        exist_ok=True,
    )

    report_path = (
        test_output_directory
        / f"{test_id.lower()}-identity-report.json"
    )

    summary_path = (
        test_output_directory
        / f"{test_id.lower()}-identity-summary.json"
    )

    data_path = (
        test_output_directory
        / f"{test_id.lower()}-data.txt"
    )

    report: dict[str, Any] = {
        "test_id": test_id,
        "timestamp_utc": utc_isoformat(),
        "credential_mode_requested": args.credential_mode,
        "managed_identity_client_id_requested": (
            args.managed_identity_client_id
        ),
        "expect_token_failure": args.expect_token_failure,
        "credential_setup": {
            "success": False,
        },
        "azureml_environment": collect_azureml_environment(),
        "process": collect_process_information(),
        "output": {
            "azureml_output_argument": args.output_dir,
            "resolved_output_root": str(output_root),
            "test_output_directory": str(
                test_output_directory
            ),
            "report_path": str(report_path),
            "identity_summary_path": str(summary_path),
            "data_file_path": str(data_path),
        },
        "token_checks": {},
    }

    credential: Any | None = None
    process_exit_code = 1

    try:
        credential, credential_class = create_credential(
            credential_mode=args.credential_mode,
            managed_identity_client_id=(
                args.managed_identity_client_id
            ),
        )

        report["credential_class"] = credential_class

        report["credential_setup"] = {
            "success": True,
            "credential_class": credential_class,
        }

        print(
            f"Credential setup succeeded: {credential_class}",
            file=sys.stderr,
        )

        for token_name, scope in TOKEN_SCOPES.items():
            report["token_checks"][token_name] = (
                acquire_token_claims(
                    credential=credential,
                    scope=scope,
                )
            )

        expected_result, process_exit_code = (
            evaluate_expected_result(
                token_checks=report["token_checks"],
                expect_token_failure=(
                    args.expect_token_failure
                ),
            )
        )

        report["expected_result"] = expected_result

    except Exception as exc:
        report["credential_setup"] = {
            "success": False,
            "error_type": type(exc).__name__,
            "error": str(exc),
            "traceback": traceback.format_exc(),
        }

        report["expected_result"] = {
            "expect_token_failure": (
                args.expect_token_failure
            ),
            "passed": False,
            "message": (
                "The credential could not be constructed, so "
                "the token behavior could not be tested."
            ),
        }

        process_exit_code = 4

        print(
            f"Credential setup failed: "
            f"{type(exc).__name__}: {exc}",
            file=sys.stderr,
        )

    finally:
        if credential is not None:
            close_credential(credential)

    summary = build_identity_summary(report)
    data_file_content = build_data_file_content(report)

    write_json(report_path, report)
    write_json(summary_path, summary)
    write_text(data_path, data_file_content)

    files_written = [
        str(report_path),
        str(summary_path),
        str(data_path),
    ]

    report["files_written"] = files_written

    # Rewrite the full report once files_written is known.
    write_json(report_path, report)

    print(
        json.dumps(
            report,
            indent=2,
            sort_keys=True,
            ensure_ascii=False,
        )
    )

    print(
        f"OUTPUT_ROOT={output_root}",
        file=sys.stderr,
    )

    print(
        f"TEST_OUTPUT_DIR={test_output_directory}",
        file=sys.stderr,
    )

    print(
        f"REPORT_PATH={report_path}",
        file=sys.stderr,
    )

    print(
        f"IDENTITY_SUMMARY_PATH={summary_path}",
        file=sys.stderr,
    )

    print(
        f"DATA_FILE_PATH={data_path}",
        file=sys.stderr,
    )

    if report["expected_result"]["passed"]:
        print(
            "IDENTITY_TEST_RESULT=PASS",
            file=sys.stderr,
        )
    else:
        print(
            "IDENTITY_TEST_RESULT=FAIL",
            file=sys.stderr,
        )

    return process_exit_code


if __name__ == "__main__":
    raise SystemExit(main())