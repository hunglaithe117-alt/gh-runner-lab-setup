#!/usr/bin/env python3
"""Renders a requirements profile into cloud-init user-data and Ansible vars.

One profile under requirements/<name>.yml is the single source of truth for a
project's package requirements. This tool validates it against a strict
allowlist and emits the two files both provisioning paths consume:

    cloud-init/user-data.yaml    first-boot baseline, applied once
    ansible/vars/generated.yml   idempotent convergence vars (gen_* prefix)

Top-level keys starting with `x-` are ignored anchor containers, the
docker-compose convention: they exist so a profile can define a reusable
`&anchor` that a `<<:` merge elsewhere pulls in.

Usage:
    render.py --profile requirements/minimal.yml [--out-dir DIR] [--check]
    render.py --list
"""

from __future__ import annotations

import argparse
import difflib
import os
import re
import shlex
import sys
import tempfile
from dataclasses import asdict, dataclass
from pathlib import Path
from typing import Final

import yaml

KIT_ROOT: Final = Path(__file__).resolve().parents[1]
PROFILE_DIR: Final = KIT_ROOT / "requirements"
DEFAULT_IMAGE: Final = "images:ubuntu/26.04/cloud"
DEFAULT_RUNNER_USER: Final = "ubuntu"
DEFAULT_UNIXSOCKET: Final = "/run/redis/redis-server.sock"
DEFAULT_UNIXSOCKETPERM: Final = "766"
# Incus-safe: no trailing hyphen and at most 60 characters. The cap leaves room
# for the "-<n>" suffix setup.sh appends, so every generated container name stays
# inside Incus's 63-character limit.
NAME_PATTERN: Final = re.compile(r"^[a-z0-9]([a-z0-9-]{0,58}[a-z0-9])?$")
ROLE_PATTERN: Final = re.compile(r"^[a-z_][a-z0-9_-]*$")
USER_PATTERN: Final = re.compile(r"^[a-z_][a-z0-9_-]*$")
LOCALE_PATTERN: Final = re.compile(r"^[A-Za-z]{2,3}_[A-Za-z]{2}(\.[A-Za-z0-9-]+)?$")
SOCKET_PATTERN: Final = re.compile(r"^/[A-Za-z0-9._/-]+$")
PERM_PATTERN: Final = re.compile(r"^[0-7]{3,4}$")
ENV_KEY_PATTERN: Final = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*$")
SYSCTL_KEY_PATTERN: Final = re.compile(r"^[A-Za-z0-9_.-]+$")
CONTROL_CHARS: Final = re.compile(r"[\x00-\x1f\x7f]")
PLAIN_SCALAR: Final = re.compile(r"^[A-Za-z0-9._+~:/-]+$")
# Top-level keys under this prefix hold anchors for `<<:` merges and nothing else.
ANCHOR_PREFIX: Final = "x-"
DIFF_LINE_LIMIT: Final = 40
# Peer auth compares the OS user to the role name, so a privileged account
# would hand the runner superuser rights over every database.
UNSUPPORTED_USERS: Final = frozenset({"root", "postgres"})
# The runner wrapper owns these names: GH_* is how it reaches the API and the
# runner itself, LD_* is read by the dynamic loader of every job process, and
# the rest change how bash resolves commands and its own startup files.
RESERVED_ENV_PREFIXES: Final = ("GH_", "LD_")
RESERVED_ENV_NAMES: Final = frozenset(
    {
        "PATH",
        "HOME",
        "SHELL",
        "IFS",
        "BASH_ENV",
        "LD_PRELOAD",
        "LD_LIBRARY_PATH",
        "ENV",
        "PYTHONPATH",
    }
)
# Services cloud-init provisions itself need their server package present in
# the same first boot: the wiring below runs before Ansible is ever reachable.
SERVICE_PACKAGES: Final = (
    ("postgresql", "services.postgres.enabled"),
    ("redis-server", "services.redis.enabled"),
)

TOP_LEVEL_KEYS: Final = frozenset(
    {
        "name",
        "description",
        "image",
        "runner_user",
        "timezone",
        "locale",
        "apt",
        "python",
        "node",
        "services",
        "sysctl",
        "env",
    }
)
APT_KEYS: Final = frozenset({"update", "packages", "repositories"})
REPOSITORY_KEYS: Final = frozenset(
    {"name", "uri", "suite", "components", "key_url", "packages"}
)
PYTHON_KEYS: Final = frozenset({"uv_tools"})
NODE_KEYS: Final = frozenset({"major", "npm_globals"})
SERVICES_KEYS: Final = frozenset({"postgres", "redis"})
POSTGRES_KEYS: Final = frozenset({"enabled", "role"})
REDIS_KEYS: Final = frozenset({"enabled", "unixsocket", "unixsocketperm"})

INFO_SCRIPT: Final = """\
#!/bin/bash
# Prints this container's name and primary IPv4 address.
name="$(hostname)"
if command -v ip >/dev/null 2>&1; then
  addr="$(ip -4 -o addr show dev eth0 | awk '{print $4}' | cut -d/ -f1)"
else
  addr="$(hostname -I | awk '{print $1}')"
fi
printf 'container: %s\\nipv4: %s\\n' "$name" "${addr:-unknown}"
"""


class StrictLoader(yaml.SafeLoader):
    """SafeLoader that refuses duplicate mapping keys.

    A copied profile with two `apt:` blocks would otherwise keep the last one
    and silently drop packages the author believes are installed.
    """


MERGE_TAG: Final = "tag:yaml.org,2002:merge"


def _construct_unique_mapping(
    loader: StrictLoader, node: yaml.MappingNode, deep: bool = False
) -> dict[object, object]:
    """Rejects duplicate explicit keys, then resolves YAML merge keys.

    Only keys the author typed are checked: a `<<` merge that repeats an
    explicit key is the intended override, not a mistake.
    """
    seen: set[object] = set()
    for key_node, _ in node.value:
        if key_node.tag == MERGE_TAG or not isinstance(key_node, yaml.ScalarNode):
            continue
        key = loader.construct_object(key_node, deep=deep)
        if key in seen:
            raise yaml.constructor.ConstructorError(
                None,
                None,
                f"duplicate key '{key}' at line {key_node.start_mark.line + 1}",
                key_node.start_mark,
            )
        seen.add(key)
    loader.flatten_mapping(node)
    return yaml.SafeLoader.construct_mapping(loader, node, deep)


StrictLoader.add_constructor(
    yaml.resolver.BaseResolver.DEFAULT_MAPPING_TAG, _construct_unique_mapping
)


@dataclass(frozen=True)
class Repository:
    """One extra APT repository and the packages it unlocks."""

    name: str
    uri: str
    suite: str
    components: list[str]
    key_url: str
    packages: list[str]


@dataclass(frozen=True)
class ServiceConfig:
    """Services requested by a profile, defaults already applied."""

    postgres_enabled: bool
    postgres_role: str
    redis_enabled: bool
    redis_unixsocket: str
    redis_unixsocketperm: str


@dataclass(frozen=True)
class Profile:
    """A validated requirements profile with every default applied."""

    name: str
    description: str
    image: str
    runner_user: str
    timezone: str
    locale: str
    apt_update: bool
    apt_packages: list[str]
    apt_repositories: list[Repository]
    uv_tools: list[str]
    node_major: int
    npm_globals: list[str]
    postgres_enabled: bool
    postgres_role: str
    redis_enabled: bool
    redis_unixsocket: str
    redis_unixsocketperm: str
    sysctl: dict[str, str]
    env: dict[str, str]


class Errors:
    """Validation messages, each prefixed with the profile path."""

    def __init__(self, path: Path) -> None:
        self._path = path
        self._messages: list[str] = []

    def add(self, where: str, message: str) -> None:
        """Records a failure at a dotted location inside the profile."""
        location = f": {where}" if where else ""
        self._messages.append(f"render: {self._path}{location}: {message}")

    @property
    def messages(self) -> list[str]:
        """All collected messages, in discovery order."""
        return self._messages

    def __bool__(self) -> bool:
        return bool(self._messages)


def _scalar_text(value: object) -> str:
    """Returns the shell text form of a scalar profile value."""
    if isinstance(value, bool):
        return "true" if value else "false"
    return str(value)


def _shell_quote(value: str) -> str:
    """Wraps a value in double quotes for a systemd and shell env assignment.

    Only the four characters both parsers escape identically are escaped: a
    backslash, a double quote, a dollar sign and a backtick. Every backslash
    emitted here is one systemd's EnvironmentFile parser and the shell both
    understand, so an unknown-escape divergence is impossible; a single quote
    needs none inside double quotes, and systemd strips the outer pair.
    """
    escaped = (
        value.replace("\\", "\\\\")
        .replace('"', '\\"')
        .replace("$", "\\$")
        .replace("`", "\\`")
    )
    return f'"{escaped}"'


def _yaml_scalar(text: str) -> str:
    """Returns text as a YAML scalar, quoted when a plain form would reparse."""
    if PLAIN_SCALAR.fullmatch(text) and yaml.safe_load(text) == text:
        return text
    return "'" + text.replace("'", "''") + "'"


def _reject_unknown(
    errors: Errors,
    where: str,
    mapping: dict[object, object],
    allowed: frozenset[str],
    allow_prefix: str = "",
) -> None:
    """Reports every key outside the allowlist for this level."""
    for key in mapping:
        if allow_prefix and isinstance(key, str) and key.startswith(allow_prefix):
            continue
        if not isinstance(key, str):
            errors.add(where, f"key {key!r} must be a string")
        elif key not in allowed:
            choices = ", ".join(sorted(allowed))
            errors.add(where, f"unknown key '{key}' (allowed: {choices})")


def _reject_null(errors: Errors, document: dict[str, object], key: str) -> None:
    """An explicit null is ambiguous: absent and empty are not the same."""
    if key in document and document[key] is None:
        errors.add(key, "null is ambiguous, omit the block or write '{}'")


def _mapping(
    errors: Errors,
    where: str,
    raw: dict[str, object],
    key: str,
    allowed: frozenset[str],
) -> dict[str, object]:
    """Returns the nested mapping at key with its keys checked, or {}."""
    value = raw.get(key)
    if value is None:
        return {}
    if not isinstance(value, dict):
        errors.add(where, "must be a mapping")
        return {}
    _reject_unknown(errors, where, value, allowed)
    return {str(name): item for name, item in value.items() if isinstance(name, str)}


def _dedupe(values: list[str]) -> list[str]:
    """Collapses duplicates to their first occurrence; the schema forbids them."""
    seen: set[str] = set()
    unique: list[str] = []
    for value in values:
        if value in seen:
            continue
        seen.add(value)
        unique.append(value)
    return unique


def _package_list(errors: Errors, where: str, value: object) -> list[str]:
    """Validates package names: trimmed, non-empty, never option-like."""
    if value is None:
        return []
    if not isinstance(value, list):
        errors.add(where, "must be a list of package names")
        return []
    names: list[str] = []
    for index, item in enumerate(value):
        if not isinstance(item, str):
            errors.add(f"{where}[{index}]", "must be a string")
            continue
        name = item.strip()
        if not name:
            errors.add(f"{where}[{index}]", "must not be empty")
            continue
        if name.startswith("-"):
            errors.add(
                f"{where}[{index}]",
                f"'{name}' starts with '-', which apt and npm read as an option",
            )
            continue
        names.append(name)
    return _dedupe(names)


def _word_list(errors: Errors, where: str, value: object) -> list[str]:
    """Validates a list of non-empty words such as repository components."""
    if value is None:
        return []
    if not isinstance(value, list):
        errors.add(where, "must be a list of non-empty strings")
        return []
    entries: list[str] = []
    for index, item in enumerate(value):
        if not isinstance(item, str) or not item.strip():
            errors.add(f"{where}[{index}]", "must be a non-empty string")
            continue
        entries.append(item)
    return _dedupe(entries)


def _env_map(errors: Errors, value: object) -> dict[str, str]:
    """Validates the flat env map written into /etc/runner-env.sh."""
    if value is None:
        return {}
    if not isinstance(value, dict):
        errors.add("env", "must be a flat mapping of scalar values")
        return {}
    entries: dict[str, str] = {}
    for key, item in value.items():
        if not isinstance(key, str) or not ENV_KEY_PATTERN.fullmatch(key):
            errors.add("env", f"key {key!r} must match ^[A-Za-z_][A-Za-z0-9_]*$")
            continue
        if key.startswith(RESERVED_ENV_PREFIXES) or key in RESERVED_ENV_NAMES:
            errors.add(f"env.{key}", "reserved name; the runner wrapper owns it")
            continue
        if item is None or isinstance(item, (dict, list)):
            errors.add(f"env.{key}", "must be a scalar value")
            continue
        text = item if isinstance(item, str) else _scalar_text(item)
        if CONTROL_CHARS.search(text):
            errors.add(
                f"env.{key}",
                "must not contain control characters (newline, tab, carriage return)",
            )
            continue
        entries[key] = text
    return entries


def _sysctl_map(errors: Errors, value: object) -> dict[str, str]:
    """Validates the flat sysctl map written into the drop-in file."""
    if value is None:
        return {}
    if not isinstance(value, dict):
        errors.add("sysctl", "must be a flat mapping of scalar values")
        return {}
    entries: dict[str, str] = {}
    for key, item in value.items():
        if not isinstance(key, str) or not SYSCTL_KEY_PATTERN.fullmatch(key):
            errors.add("sysctl", f"key {key!r} must match ^[A-Za-z0-9_.-]+$")
            continue
        if isinstance(item, bool):
            errors.add(f"sysctl.{key}", "boolean is ambiguous, use 1 or 0")
            continue
        if not isinstance(item, (str, int)):
            errors.add(f"sysctl.{key}", "must be a string or an integer")
            continue
        text = item if isinstance(item, str) else str(item)
        if CONTROL_CHARS.search(text):
            errors.add(
                f"sysctl.{key}",
                "must not contain control characters (newline, tab, carriage return)",
            )
            continue
        entries[key] = text
    return entries


def _boolean(errors: Errors, where: str, value: object, default: bool) -> bool:
    """Returns a boolean, complaining when the written value is not one."""
    if value is None:
        return default
    if not isinstance(value, bool):
        errors.add(where, "must be true or false")
        return default
    return value


def _optional_text(errors: Errors, where: str, value: object) -> str:
    """Returns a possibly empty string; absent keys yield ""."""
    if value is None:
        return ""
    if not isinstance(value, str):
        errors.add(where, "must be a string")
        return ""
    return value


def _text(errors: Errors, where: str, value: object, default: str) -> str:
    """Returns a non-empty string, or the default when the key is absent."""
    if value is None:
        return default
    if not isinstance(value, str) or not value:
        errors.add(where, "must be a non-empty string")
        return default
    return value


def _profile_name(errors: Errors, value: object) -> str:
    """Validates the required name, which becomes a filename."""
    if value is None:
        errors.add("", "missing required key 'name'")
        return ""
    if not isinstance(value, str) or not NAME_PATTERN.fullmatch(value):
        errors.add(
            "name",
            "must match ^[a-z0-9]([a-z0-9-]{0,58}[a-z0-9])?$ "
            "(it names a sysctl file and an Incus profile)",
        )
        return ""
    return value


def _runner_user(errors: Errors, value: object) -> str:
    """Validates the unprivileged user that owns the runner."""
    user = _text(errors, "runner_user", value, DEFAULT_RUNNER_USER)
    if not user:
        return user
    if not USER_PATTERN.fullmatch(user):
        errors.add(
            "runner_user", "must match ^[a-z_][a-z0-9_-]*$ and name an existing OS user"
        )
        return user
    if len(user) > 32:
        errors.add("runner_user", "must be at most 32 characters")
    if user in UNSUPPORTED_USERS:
        errors.add(
            "runner_user", f"'{user}' is not supported; run jobs as a non-root user"
        )
    return user


def _locale(errors: Errors, value: object) -> str:
    """Validates a locale such as en_US or en_US.UTF-8."""
    locale = _optional_text(errors, "locale", value)
    if not locale:
        return locale
    if not LOCALE_PATTERN.fullmatch(locale):
        errors.add("locale", "must look like en_US or en_US.UTF-8")
        return ""
    return locale


def _repositories(errors: Errors, value: object) -> list[Repository]:
    """Validates the apt.repositories entries."""
    if value is None:
        return []
    if not isinstance(value, list):
        errors.add("apt.repositories", "must be a list of repository mappings")
        return []
    repositories: list[Repository] = []
    for index, entry in enumerate(value):
        where = f"apt.repositories[{index}]"
        if not isinstance(entry, dict):
            errors.add(where, "must be a mapping")
            continue
        _reject_unknown(errors, where, entry, REPOSITORY_KEYS)
        item = {str(k): v for k, v in entry.items() if isinstance(k, str)}
        missing = [
            key for key in ("name", "uri", "suite", "components") if key not in item
        ]
        for key in missing:
            errors.add(where, f"missing required key '{key}'")
        name = _text(errors, f"{where}.name", item.get("name"), "")
        if name and not NAME_PATTERN.fullmatch(name):
            errors.add(
                f"{where}.name", "must match ^[a-z0-9]([a-z0-9-]{0,58}[a-z0-9])?$"
            )
        components = _word_list(errors, f"{where}.components", item.get("components"))
        if "components" in item and not components:
            errors.add(f"{where}.components", "must list at least one component")
        repositories.append(
            Repository(
                name=name,
                uri=_text(errors, f"{where}.uri", item.get("uri"), ""),
                suite=_text(errors, f"{where}.suite", item.get("suite"), ""),
                components=components,
                key_url=_text(errors, f"{where}.key_url", item.get("key_url"), ""),
                packages=_package_list(
                    errors, f"{where}.packages", item.get("packages")
                ),
            )
        )
    return repositories


def _node_major(errors: Errors, value: object) -> int:
    """Validates node.major; 0 means Node is not part of this profile."""
    if value is None:
        return 0
    if isinstance(value, bool) or not isinstance(value, int) or value < 1:
        errors.add("node.major", "must be a positive integer")
        return 0
    return value


def _unixsocketperm(errors: Errors, value: object) -> str:
    """Requires the quoted string form so the octal digits survive YAML."""
    if value is None:
        return DEFAULT_UNIXSOCKETPERM
    if isinstance(value, int):
        errors.add(
            "services.redis.unixsocketperm",
            "must be a quoted string like '766' "
            "(YAML reads 0766 as an integer and loses the octal meaning)",
        )
        return DEFAULT_UNIXSOCKETPERM
    if not isinstance(value, str) or not PERM_PATTERN.fullmatch(value):
        errors.add(
            "services.redis.unixsocketperm", "must be an octal string like '766'"
        )
        return DEFAULT_UNIXSOCKETPERM
    return value


def _unixsocket(errors: Errors, value: object) -> str:
    """Validates the socket path, which is spliced into a sed expression."""
    socket = _text(errors, "services.redis.unixsocket", value, DEFAULT_UNIXSOCKET)
    if not socket:
        return socket
    if not socket.startswith("/"):
        errors.add("services.redis.unixsocket", "must be an absolute path")
        return DEFAULT_UNIXSOCKET
    if not SOCKET_PATTERN.fullmatch(socket):
        offenders = sorted(
            {char for char in socket if not re.match(r"[A-Za-z0-9._/-]", char)}
        )
        errors.add(
            "services.redis.unixsocket",
            f"uses {', '.join(repr(char) for char in offenders)}; only "
            "[A-Za-z0-9._/-] is allowed (quotes, backslashes, '&', spaces and "
            "'|' would break the sed expression)",
        )
        return DEFAULT_UNIXSOCKET
    return socket


def _postgres_role(
    errors: Errors, postgres: dict[str, object], runner_user: str, enabled: bool
) -> str:
    """Validates the peer-auth role, which must equal the OS user."""
    role = _text(errors, "services.postgres.role", postgres.get("role"), runner_user)
    if not enabled or not role:
        return role
    if not ROLE_PATTERN.fullmatch(role):
        errors.add("services.postgres.role", "must match ^[a-z_][a-z0-9_-]*$")
    elif role != runner_user:
        errors.add(
            "services.postgres.role",
            f"must equal runner_user ('{runner_user}'); peer auth compares them",
        )
    return role


def _service_block(
    errors: Errors,
    services: dict[str, object],
    key: str,
    allowed: frozenset[str],
) -> tuple[bool, dict[str, object]]:
    """Returns (present, block); an explicit null is ambiguous, not 'off'."""
    if key not in services:
        return False, {}
    value = services[key]
    if value is None:
        errors.add(
            f"services.{key}",
            f"null is ambiguous, write '{key}: {{}}' or 'enabled: false'",
        )
        return False, {}
    if not isinstance(value, dict):
        errors.add(f"services.{key}", "must be a mapping")
        return False, {}
    _reject_unknown(errors, f"services.{key}", value, allowed)
    return True, {str(k): v for k, v in value.items() if isinstance(k, str)}


def _parse_services(
    errors: Errors, document: dict[str, object], runner_user: str
) -> ServiceConfig:
    """Validates the services block; a present block enables the service."""
    services = _mapping(errors, "services", document, "services", SERVICES_KEYS)
    postgres_present, postgres = _service_block(
        errors, services, "postgres", POSTGRES_KEYS
    )
    redis_present, redis = _service_block(errors, services, "redis", REDIS_KEYS)
    postgres_enabled = _boolean(
        errors, "services.postgres.enabled", postgres.get("enabled"), postgres_present
    )
    return ServiceConfig(
        postgres_enabled=postgres_enabled,
        postgres_role=_postgres_role(errors, postgres, runner_user, postgres_enabled),
        redis_enabled=_boolean(
            errors, "services.redis.enabled", redis.get("enabled"), redis_present
        ),
        redis_unixsocket=_unixsocket(errors, redis.get("unixsocket")),
        redis_unixsocketperm=_unixsocketperm(errors, redis.get("unixsocketperm")),
    )


def _parse_node(errors: Errors, node: dict[str, object]) -> tuple[int, list[str]]:
    """Validates node.major and npm_globals, which depend on each other."""
    major = _node_major(errors, node.get("major"))
    globals_ = _package_list(errors, "node.npm_globals", node.get("npm_globals"))
    if globals_ and not major:
        errors.add(
            "node.major",
            "must be set because node.npm_globals is not empty; "
            "npm globals need a Node version",
        )
    return major, globals_


def parse_profile(raw: object, path: Path, errors: Errors) -> Profile | None:
    """Validates the parsed YAML document and applies every default."""
    if not isinstance(raw, dict):
        errors.add("", "top level must be a mapping of profile keys")
        return None
    _reject_unknown(errors, "", raw, TOP_LEVEL_KEYS, allow_prefix=ANCHOR_PREFIX)
    document = {
        str(key): value
        for key, value in raw.items()
        if isinstance(key, str) and not key.startswith(ANCHOR_PREFIX)
    }
    for key in ("apt", "python", "node", "services", "sysctl", "env"):
        _reject_null(errors, document, key)

    runner_user = _runner_user(errors, document.get("runner_user"))
    apt = _mapping(errors, "apt", document, "apt", APT_KEYS)
    python = _mapping(errors, "python", document, "python", PYTHON_KEYS)
    node = _mapping(errors, "node", document, "node", NODE_KEYS)
    services = _parse_services(errors, document, runner_user)

    node_major, npm_globals = _parse_node(errors, node)

    profile = Profile(
        name=_profile_name(errors, document.get("name")),
        description=_optional_text(errors, "description", document.get("description")),
        image=_text(errors, "image", document.get("image"), DEFAULT_IMAGE),
        runner_user=runner_user,
        timezone=_optional_text(errors, "timezone", document.get("timezone")),
        locale=_locale(errors, document.get("locale")),
        apt_update=_boolean(errors, "apt.update", apt.get("update"), True),
        apt_packages=_package_list(errors, "apt.packages", apt.get("packages")),
        apt_repositories=_repositories(errors, apt.get("repositories")),
        uv_tools=_package_list(errors, "python.uv_tools", python.get("uv_tools")),
        node_major=node_major,
        npm_globals=npm_globals,
        postgres_enabled=services.postgres_enabled,
        postgres_role=services.postgres_role,
        redis_enabled=services.redis_enabled,
        redis_unixsocket=services.redis_unixsocket,
        redis_unixsocketperm=services.redis_unixsocketperm,
        sysctl=_sysctl_map(errors, document.get("sysctl")),
        env=_env_map(errors, document.get("env")),
    )
    return None if errors else profile


def load_profile(path: Path) -> tuple[Profile | None, list[str]]:
    """Reads, parses and validates one profile file."""
    errors = Errors(path)
    try:
        text = path.read_text(encoding="utf-8")
    except OSError as exc:
        return None, [f"render: {path}: cannot read profile: {exc.strerror}"]
    except UnicodeDecodeError as exc:
        return None, [f"render: {path}: cannot read profile: not UTF-8 ({exc.reason})"]
    try:
        # StrictLoader subclasses SafeLoader, so this is a safe load with
        # duplicate-key detection.
        raw = yaml.load(text, Loader=StrictLoader)
    except yaml.YAMLError as exc:
        return None, [f"render: {path}: cannot read profile: {exc}"]
    return parse_profile(raw, path, errors), errors.messages


def enabled_service_packages(profile: Profile) -> list[tuple[str, str]]:
    """Returns (package, profile switch) for each enabled service."""
    packages: list[tuple[str, str]] = []
    if profile.postgres_enabled:
        packages.append(SERVICE_PACKAGES[0])
    if profile.redis_enabled:
        packages.append(SERVICE_PACKAGES[1])
    return packages


def service_package_names(profile: Profile) -> list[str]:
    """Returns the service package names, for gen_service_packages."""
    return [name for name, _ in enabled_service_packages(profile)]


def injected_packages(profile: Profile) -> list[tuple[str, str]]:
    """Returns (package, reason) for every entry the profile implies.

    cloud-init needs each of these present on the first boot, before Ansible is
    reachable: the service wiring and locale-gen both run there. The locale and
    timezone packages are not in gen_service_packages because prepare.yml
    installs them itself when the corresponding gen_* value is set.
    """
    packages: list[tuple[str, str]] = []
    for name, switch in enabled_service_packages(profile):
        packages.append((name, f"{switch} is true"))
    if profile.locale:
        packages.append(("locales", "locale is set"))
    if profile.timezone:
        packages.append(("tzdata", "timezone is set"))
    return packages


def build_packages_block(profile: Profile) -> str:
    """Emits the packages: block with a comment over each injected entry.

    Written by hand because PyYAML cannot emit comments, and the comment is
    what tells a reader why a package they never listed is being installed.
    """
    packages = list(profile.apt_packages)
    notes: dict[str, str] = {}
    for name, reason in injected_packages(profile):
        if name in packages:
            continue
        packages.append(name)
        notes[name] = f"# added by render.py because {reason}"
    if not packages:
        return ""
    lines = ["packages:"]
    for name in packages:
        if name in notes:
            lines.append(notes[name])
        lines.append(f"- {_yaml_scalar(name)}")
    return "\n".join(lines) + "\n"


def build_write_files(profile: Profile) -> list[dict[str, object]]:
    """Builds the cloud-init write_files entries for this profile."""
    files: list[dict[str, object]] = []
    if profile.sysctl:
        content = "".join(f"{key} = {value}\n" for key, value in profile.sysctl.items())
        files.append(
            {
                "path": f"/etc/sysctl.d/60-{profile.name}.conf",
                "permissions": "0644",
                "owner": "root:root",
                "content": content,
            }
        )
    # KEY="value", no `export ` prefix: systemd reads everything before the `=`
    # as the name and would name the variable `export KEY`, while a shell
    # consumer runs `set -a` before sourcing. _shell_quote escapes only the four
    # characters both parsers agree on, so they read back identical values.
    # The two comment lines are byte-identical to what prepare.yml writes, so
    # the first `prepare` after `create` reports no change.
    if profile.env:
        content = (
            "# Read by the runner's systemd unit. Not a secret store: this file is\n"
            "# readable by the runner's group and baked into the container image.\n"
            + "".join(
                f"{key}={_shell_quote(value)}\n" for key, value in profile.env.items()
            )
        )
        files.append(
            {
                "path": "/etc/runner-env.sh",
                "permissions": "0640",
                "owner": "root:root",
                "content": content,
            }
        )
    files.append(
        {
            "path": "/usr/local/bin/gh-runner-info",
            "permissions": "0755",
            "owner": "root:root",
            "content": INFO_SCRIPT,
        }
    )
    return files


def build_shell_block(steps: list[list[str]]) -> str:
    """Aggregates independent steps so one failure cannot abort the rest.

    Each step runs in its own subshell with `set -eu`; the script records the
    failure and exits non-zero at the end, which keeps a broken Redis rewrite
    from skipping the PostgreSQL role and the env-file group fix.
    """
    lines = ["failed=0"]
    for step in steps:
        lines.append("( set -eu")
        lines.extend(f"  {line}" if line else "" for line in step)
        lines.append(") || failed=1")
    lines.append('exit "$failed"')
    return "\n".join(lines) + "\n"


def redis_block_lines(profile: Profile) -> list[str]:
    """Lines that rewrite the redis socket directives in place."""
    socket = profile.redis_unixsocket
    perm = profile.redis_unixsocketperm
    return [
        "# Ubuntu's redis-server has no conf.d include, so rewrite the two socket",
        "# directives in place. Both seds match the commented and the rewritten",
        "# line, which keeps a manual re-run of this snippet harmless.",
        # The unit owns the mode through RuntimeDirectory=, so an existing
        # directory is left alone instead of being recreated every boot.
        'redis_dir="$(dirname ' + shlex.quote(socket) + ')"',
        '[ -d "$redis_dir" ] || install -d -o redis -g redis -m 0775 "$redis_dir"',
        "sed -i -E \\",
        "  -e 's|^#?[[:space:]]*unixsocket[[:space:]]+.*|unixsocket "
        + socket
        + "|' \\",
        "  -e 's|^#?[[:space:]]*unixsocketperm[[:space:]]+.*|unixsocketperm "
        + perm
        + "|' \\",
        "  /etc/redis/redis.conf",
        "systemctl restart redis-server",
    ]


def postgres_block_lines(profile: Profile) -> list[str]:
    """Lines that create the peer-auth superuser role."""
    role = profile.postgres_role
    return [
        "# Peer auth over the unix socket: the login user owns the databases, so no",
        "# password is stored anywhere in the image.",
        "for _ in 1 2 3 4 5 6 7 8 9 10; do",
        "  pg_isready -q && break",
        "  sleep 2",
        "done",
        'su postgres -c "psql -tAc \\"SELECT 1 FROM pg_roles WHERE rolname='
        + f"'{role}'"
        + '\\"" \\',
        "  | grep -q 1 \\",
        f'  || su postgres -c "psql -c \'CREATE ROLE \\"{role}\\" SUPERUSER LOGIN\'"',
    ]


def build_runcmd(profile: Profile) -> list[str]:
    """Builds the single runcmd script, steps in dependency order."""
    steps: list[list[str]] = []
    if profile.sysctl:
        steps.append(["sysctl --system"])
    if profile.locale:
        # locales is in the package list above for exactly this step, so a
        # failure here is a real failure, not a missing package.
        steps.append([f"locale-gen {shlex.quote(profile.locale)}"])
    if profile.redis_enabled:
        steps.append(redis_block_lines(profile))
    if profile.postgres_enabled:
        steps.append(postgres_block_lines(profile))
    if profile.env:
        # /etc/runner-env.sh is 0640 root:root until the runner's group exists.
        # The group is looked up from the account: images routinely name the
        # primary group differently from the user, so guessing would fail.
        user = profile.runner_user
        steps.append(
            [
                f'group="$(id -gn {shlex.quote(user)} 2>/dev/null)" \\',
                "  || { echo \"runner_user '" + user + "' does not exist in"
                ' this image" >&2; exit 1; }',
                'chgrp "$group" /etc/runner-env.sh',
            ]
        )
    return [build_shell_block(steps)] if steps else []


def build_cloud_init(profile: Profile) -> dict[str, object]:
    """Builds the cloud-init document, packages excluded.

    render_cloud_init() emits the packages: block separately so it can carry
    the per-service comments.
    """
    document: dict[str, object] = {"package_update": profile.apt_update}
    if profile.timezone:
        document["timezone"] = profile.timezone
    if profile.locale:
        document["locale"] = profile.locale
    document["write_files"] = build_write_files(profile)
    commands = build_runcmd(profile)
    if commands:
        document["runcmd"] = commands
    return document


def build_vars(profile: Profile) -> dict[str, object]:
    """Builds the flat gen_* map consumed by the Phase 2 playbook."""
    return {
        "gen_name": profile.name,
        "gen_image": profile.image,
        "gen_runner_user": profile.runner_user,
        "gen_timezone": profile.timezone,
        "gen_locale": profile.locale,
        "gen_apt_update": profile.apt_update,
        "gen_apt_packages": list(profile.apt_packages),
        "gen_service_packages": service_package_names(profile),
        "gen_apt_repositories": [asdict(entry) for entry in profile.apt_repositories],
        "gen_uv_tools": list(profile.uv_tools),
        "gen_node_major": profile.node_major,
        "gen_node_enabled": profile.node_major > 0,
        "gen_npm_globals": list(profile.npm_globals),
        "gen_postgres_enabled": profile.postgres_enabled,
        "gen_postgres_role": profile.postgres_role,
        "gen_redis_enabled": profile.redis_enabled,
        "gen_redis_unixsocket": profile.redis_unixsocket,
        "gen_redis_unixsocketperm": profile.redis_unixsocketperm,
        "gen_sysctl": dict(profile.sysctl),
        "gen_env": dict(profile.env),
    }


class BlockDumper(yaml.SafeDumper):
    """SafeDumper that writes multi-line strings as literal blocks."""


def _represent_str(dumper: yaml.SafeDumper, value: str) -> yaml.ScalarNode:
    """Emits multi-line strings as `|` blocks, everything else as-is."""
    style = "|" if "\n" in value else None
    return dumper.represent_scalar("tag:yaml.org,2002:str", value, style=style)


BlockDumper.add_representer(str, _represent_str)


def dump_yaml(document: dict[str, object]) -> str:
    """Serialises a document deterministically, key order preserved."""
    return yaml.dump(
        document,
        Dumper=BlockDumper,
        sort_keys=False,
        default_flow_style=False,
        allow_unicode=True,
        width=4096,
    )


def source_label(profile_path: Path) -> str:
    """Returns a stable, machine-independent name for the source profile."""
    resolved = profile_path.resolve()
    try:
        return str(resolved.relative_to(KIT_ROOT))
    except ValueError:
        return str(profile_path)


def cloud_init_header(source: str) -> str:
    """Returns the fixed comment block above the rendered cloud-init file."""
    return (
        "#cloud-config\n"
        f"# Generated by scripts/render.py from {source}.\n"
        "# Do not edit this file; edit the profile and re-render.\n"
        "#\n"
        "# cloud-init applies this file ONCE, at the container's first boot. It is\n"
        "# never reconciled afterwards, so a re-run on an existing container does\n"
        "# nothing.\n"
        "#\n"
        "# Boundary: cloud-init installs the apt baseline and performs the Redis\n"
        "# socket and PostgreSQL peer-role wiring. Extra apt repositories, uv\n"
        "# tools, npm globals, and any repair of an existing container are\n"
        "# Ansible-only.\n"
        "#\n"
        "# /etc/runner-env.sh is not a secret store: it holds the kit's\n"
        "# KEY=\"value\" lines, is readable by the runner's group, and is baked\n"
        "# into the image.\n"
    )


def render_cloud_init(profile: Profile, profile_path: Path) -> str:
    """Renders the complete cloud-init file, header comment included."""
    document = dump_yaml(build_cloud_init(profile))
    first_line, newline, remainder = document.partition("\n")
    packages = build_packages_block(profile)
    body = f"{first_line}{newline}{packages}{remainder}"
    return cloud_init_header(source_label(profile_path)) + body


def render_vars(profile: Profile, profile_path: Path) -> str:
    """Renders the complete Ansible vars file, header comment included."""
    header = (
        f"# Generated by scripts/render.py from {source_label(profile_path)}.\n"
        "# Do not edit this file; edit the profile and re-render.\n"
        "# gen_apt_packages: apt packages written in the profile.\n"
        "# gen_service_packages: packages added by enabled services; the\n"
        "# playbook concatenates the two lists.\n"
    )
    return header + dump_yaml(build_vars(profile))


def write_atomic(path: Path, text: str) -> None:
    """Writes text via a sibling temp file so readers never see a partial file."""
    path.parent.mkdir(parents=True, exist_ok=True)
    handle, temp_name = tempfile.mkstemp(
        dir=path.parent, prefix=f".{path.name}.", suffix=".tmp"
    )
    try:
        with os.fdopen(handle, "w", encoding="utf-8", newline="\n") as stream:
            stream.write(text)
        os.chmod(temp_name, 0o644)
        os.replace(temp_name, path)
    except BaseException:
        Path(temp_name).unlink(missing_ok=True)
        raise


def diff_summary(path: Path, rendered: str) -> list[str]:
    """Returns a short unified diff between the file on disk and the render."""
    try:
        current = path.read_text(encoding="utf-8")
    except OSError:
        return [f"render: {path}: missing, render it with --profile\n"]
    lines = list(
        difflib.unified_diff(
            current.splitlines(keepends=True),
            rendered.splitlines(keepends=True),
            fromfile=f"{path} (on disk)",
            tofile=f"{path} (rendered)",
            n=1,
        )
    )
    if len(lines) > DIFF_LINE_LIMIT:
        lines = lines[:DIFF_LINE_LIMIT] + ["... diff truncated ...\n"]
    return lines


def resolve_profile(value: str) -> Path:
    """Resolves a profile argument: a path, or a bare name under requirements/."""
    candidate = Path(value)
    if candidate.is_file():
        return candidate
    if candidate.suffix != ".yml" and (PROFILE_DIR / f"{value}.yml").is_file():
        return PROFILE_DIR / f"{value}.yml"
    return candidate


def available_profiles() -> list[str]:
    """Returns the profile names in requirements/, sorted."""
    if not PROFILE_DIR.is_dir():
        return []
    return sorted(path.stem for path in PROFILE_DIR.glob("*.yml"))


def build_targets(
    profile: Profile, profile_path: Path, out_dir: Path
) -> dict[Path, str]:
    """Maps each output path to the text it must contain."""
    return {
        out_dir / "cloud-init" / "user-data.yaml": render_cloud_init(
            profile, profile_path
        ),
        out_dir / "ansible" / "vars" / "generated.yml": render_vars(
            profile, profile_path
        ),
    }


def check_targets(targets: dict[Path, str]) -> int:
    """Returns 1 when a file on disk differs from its render, else 0."""
    stale = False
    for target, text in targets.items():
        if target.is_file() and target.read_text(encoding="utf-8") == text:
            continue
        stale = True
        sys.stdout.write("".join(diff_summary(target, text)))
        print(f"render: {target}: out of date", file=sys.stderr)
    return 1 if stale else 0


def write_targets(targets: dict[Path, str]) -> None:
    """Writes every target atomically and reports each path."""
    for target, text in targets.items():
        write_atomic(target, text)
        print(f"render: wrote {target}")


def build_parser() -> argparse.ArgumentParser:
    """Returns the command-line parser."""
    parser = argparse.ArgumentParser(
        prog="render.py",
        description="Render a requirements profile into cloud-init and Ansible artifacts.",
    )
    parser.add_argument(
        "--profile", help="profile to render, e.g. requirements/minimal.yml"
    )
    parser.add_argument(
        "--out-dir",
        help="directory that receives cloud-init/ and ansible/ (default: the kit root)",
    )
    parser.add_argument(
        "--check",
        action="store_true",
        help="render in memory and compare with the files on disk; nonzero on drift",
    )
    parser.add_argument(
        "--list", action="store_true", help="print the available profile names"
    )
    return parser


def main(argv: list[str]) -> int:
    """Entry point: parse arguments, then render, check or list profiles."""
    parser = build_parser()
    arguments = parser.parse_args(argv)

    if arguments.list:
        for name in available_profiles():
            print(name)
        return 0
    if not arguments.profile:
        parser.print_usage(sys.stderr)
        print("render: error: --profile is required (or use --list)", file=sys.stderr)
        return 2

    profile_path = resolve_profile(arguments.profile)
    profile, errors = load_profile(profile_path)
    if profile is None or errors:
        for message in errors:
            print(message, file=sys.stderr)
        return 1

    out_dir = Path(arguments.out_dir) if arguments.out_dir else KIT_ROOT
    targets = build_targets(profile, profile_path, out_dir)
    if arguments.check:
        return check_targets(targets)
    write_targets(targets)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
