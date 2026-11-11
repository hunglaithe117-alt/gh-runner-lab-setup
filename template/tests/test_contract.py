"""Contract tests for scripts/render.py and the profile schema.

Run with:
    /usr/bin/python3 -m unittest discover -s template/tests -t template
"""

from __future__ import annotations

import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

import yaml

TEMPLATE_ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(TEMPLATE_ROOT / "scripts"))

import render  # noqa: E402

SCHEMA_PATH = TEMPLATE_ROOT / "schema" / "requirements.schema.json"
PROFILE_DIR = TEMPLATE_ROOT / "requirements"


def schema() -> dict:
    """Loads the JSON Schema once per call; it is small."""
    return json.loads(SCHEMA_PATH.read_text(encoding="utf-8"))


def parse(raw: dict) -> tuple[render.Profile | None, list[str]]:
    """Runs the validator over an in-memory document."""
    errors = render.Errors(Path("<test>"))
    return render.parse_profile(raw, Path("<test>"), errors), errors.messages


def loads(text: str) -> dict:
    """Parses YAML with the renderer's duplicate-key detection."""
    return yaml.load(text, Loader=render.StrictLoader)


def validator() -> object:
    """Returns a draft 2020-12 validator, skipping if jsonschema is absent."""
    try:
        from jsonschema import Draft202012Validator
    except ImportError:
        raise unittest.SkipTest("jsonschema is not installed") from None
    return Draft202012Validator(schema())


class AllowlistContractTest(unittest.TestCase):
    """The validator and the schema must describe the same key set."""

    def test_allowlists_match_schema_properties(self) -> None:
        document = schema()
        properties = document["properties"]
        cases = {
            "TOP_LEVEL_KEYS": (render.TOP_LEVEL_KEYS, properties),
            "APT_KEYS": (render.APT_KEYS, properties["apt"]["properties"]),
            "REPOSITORY_KEYS": (
                render.REPOSITORY_KEYS,
                properties["apt"]["properties"]["repositories"]["items"]["properties"],
            ),
            "PYTHON_KEYS": (render.PYTHON_KEYS, properties["python"]["properties"]),
            "NODE_KEYS": (render.NODE_KEYS, properties["node"]["properties"]),
            "SERVICES_KEYS": (
                render.SERVICES_KEYS,
                properties["services"]["properties"],
            ),
            "POSTGRES_KEYS": (
                render.POSTGRES_KEYS,
                properties["services"]["properties"]["postgres"]["properties"],
            ),
            "REDIS_KEYS": (
                render.REDIS_KEYS,
                properties["services"]["properties"]["redis"]["properties"],
            ),
        }
        for label, (constant, section) in cases.items():
            with self.subTest(constant=label):
                self.assertEqual(set(constant), set(section))

    def test_defaults_constants_match_schema(self) -> None:
        properties = schema()["properties"]
        self.assertEqual(render.DEFAULT_IMAGE, properties["image"]["default"])
        self.assertEqual(
            render.DEFAULT_RUNNER_USER, properties["runner_user"]["default"]
        )
        self.assertEqual(
            render.DEFAULT_UNIXSOCKET,
            properties["services"]["properties"]["redis"]["properties"]["unixsocket"][
                "default"
            ],
        )
        self.assertEqual(
            render.DEFAULT_UNIXSOCKETPERM,
            properties["services"]["properties"]["redis"]["properties"][
                "unixsocketperm"
            ]["default"],
        )


class ServicePresenceTest(unittest.TestCase):
    """Presence enables a service; null is ambiguous, not "off"."""

    def test_empty_postgres_block_enables_it(self) -> None:
        profile, messages = parse({"name": "t", "services": {"postgres": {}}})
        self.assertEqual(messages, [])
        self.assertIsNotNone(profile)
        self.assertTrue(profile.postgres_enabled)
        self.assertIn("postgresql", render.service_package_names(profile))

    def test_null_postgres_block_is_rejected(self) -> None:
        profile, messages = parse({"name": "t", "services": {"postgres": None}})
        self.assertIsNone(profile)
        self.assertTrue(any("null is ambiguous" in message for message in messages))

    def test_null_redis_block_is_rejected(self) -> None:
        _, messages = parse({"name": "t", "services": {"redis": None}})
        self.assertTrue(any("null is ambiguous" in message for message in messages))

    def test_enabled_false_switches_a_present_block_off(self) -> None:
        profile, _ = parse({"name": "t", "services": {"redis": {"enabled": False}}})
        self.assertFalse(profile.redis_enabled)
        self.assertEqual(render.service_package_names(profile), [])


class RunnerUserTest(unittest.TestCase):
    """The runner user reaches a shell, a SQL identifier and a file owner."""

    def test_privileged_users_are_rejected(self) -> None:
        for user in ("root", "postgres", "Runner"):
            with self.subTest(user=user):
                _, messages = parse({"name": "t", "runner_user": user})
                self.assertTrue(
                    any("not supported" in message for message in messages)
                    or any("must match" in message for message in messages)
                )

    def test_role_is_quoted_in_sql(self) -> None:
        profile, messages = parse(
            {"name": "t", "runner_user": "app-runner", "services": {"postgres": {}}}
        )
        self.assertEqual(messages, [])
        self.assertIn(
            'CREATE ROLE \\"app-runner\\" SUPERUSER LOGIN',
            "\n".join(render.postgres_block_lines(profile)),
        )


class ValueValidationTest(unittest.TestCase):
    """Values spliced into shell and sed expressions are constrained."""

    def test_integer_socket_perm_is_rejected(self) -> None:
        _, messages = parse(
            {"name": "t", "services": {"redis": {"unixsocketperm": 766}}}
        )
        self.assertTrue(any("quoted string" in message for message in messages))

    def test_quoted_socket_perm_passes(self) -> None:
        profile, messages = parse(
            {"name": "t", "services": {"redis": {"unixsocketperm": "766"}}}
        )
        self.assertEqual(messages, [])
        self.assertEqual(profile.redis_unixsocketperm, "766")

    def test_env_key_with_space_is_rejected(self) -> None:
        _, messages = parse({"name": "t", "env": {"MY KEY": "x"}})
        self.assertTrue(any("must match ^[A-Za-z_]" in m for m in messages))

    def test_boolean_sysctl_value_is_rejected(self) -> None:
        _, messages = parse({"name": "t", "sysctl": {"a.b": True}})
        self.assertTrue(any("boolean is ambiguous" in m for m in messages))

    def test_socket_with_quote_is_rejected(self) -> None:
        _, messages = parse(
            {"name": "t", "services": {"redis": {"unixsocket": "/run/x'y.sock"}}}
        )
        self.assertTrue(any("A-Za-z0-9" in message for message in messages))

    def test_npm_globals_need_a_node_major(self) -> None:
        _, messages = parse({"name": "t", "node": {"npm_globals": ["pnpm"]}})
        self.assertTrue(any("npm globals need a Node version" in m for m in messages))

    def test_duplicate_keys_are_rejected(self) -> None:
        path = PROFILE_DIR / "_duplicate_fixture.yml"
        try:
            path.write_text("name: a\napt: {}\napt: {}\n", encoding="utf-8")
            _, messages = render.load_profile(path)
        finally:
            path.unlink(missing_ok=True)
        self.assertTrue(any("duplicate key 'apt'" in m for m in messages))


class ExampleProfileTest(unittest.TestCase):
    """The shipped examples must render and re-parse."""

    def test_examples_render_and_parse(self) -> None:
        for path in sorted(PROFILE_DIR.glob("*.yml")):
            with self.subTest(profile=path.name):
                profile, messages = render.load_profile(path)
                self.assertEqual(messages, [])
                self.assertIsNotNone(profile)
                user_data = render.render_cloud_init(profile, path)
                self.assertTrue(user_data.startswith("#cloud-config\n"))
                self.assertIsInstance(yaml.safe_load(user_data), dict)
                variables = render.render_vars(profile, path)
                self.assertIsInstance(yaml.safe_load(variables), dict)

    def test_examples_match_schema(self) -> None:
        check = validator()
        for path in sorted(PROFILE_DIR.glob("*.yml")):
            with self.subTest(profile=path.name):
                document = yaml.safe_load(path.read_text(encoding="utf-8"))
                self.assertEqual(list(check.iter_errors(document)), [])


class SchemaRuleTest(unittest.TestCase):
    """Rules the schema has to state, because the renderer cannot hint them."""

    def test_privileged_runner_user_is_invalid(self) -> None:
        check = validator()
        for user in ("root", "postgres"):
            with self.subTest(user=user):
                self.assertTrue(
                    list(check.iter_errors({"name": "x", "runner_user": user}))
                )

    def test_npm_globals_require_node_major(self) -> None:
        check = validator()
        self.assertTrue(
            list(check.iter_errors({"name": "x", "node": {"npm_globals": ["pnpm"]}}))
        )
        self.assertEqual(
            list(check.iter_errors({"name": "x", "node": {"npm_globals": []}})), []
        )

    def test_empty_locale_is_allowed(self) -> None:
        check = validator()
        self.assertEqual(list(check.iter_errors({"name": "x", "locale": ""})), [])

    def test_duplicate_packages_are_invalid(self) -> None:
        check = validator()
        self.assertTrue(
            list(check.iter_errors({"name": "x", "apt": {"packages": ["git", "git"]}}))
        )


class NullBlockTest(unittest.TestCase):
    """An explicit null is neither absent nor empty."""

    def test_null_blocks_are_rejected(self) -> None:
        for key in ("apt", "python", "node", "services", "sysctl", "env"):
            with self.subTest(block=key):
                _, messages = parse({"name": "t", key: None})
                self.assertTrue(
                    any("null is ambiguous" in message for message in messages)
                )


class MergeKeyTest(unittest.TestCase):
    """Anchors are a YAML feature users copy; duplicates are checked explicitly."""

    def test_merge_key_profile_renders(self) -> None:
        raw = loads(
            "name: merged\n"
            "<<: &defaults\n"
            "  description: from the anchor\n"
            "timezone: Asia/Ho_Chi_Minh\n"
        )
        profile, messages = parse(raw)
        self.assertEqual(messages, [])
        self.assertEqual(profile.description, "from the anchor")
        self.assertIn("#cloud-config", render.render_cloud_init(profile, Path("x.yml")))

    def test_merge_duplicate_with_explicit_key_is_allowed(self) -> None:
        raw = loads(
            "name: merged\n<<: &defaults\n  timezone: UTC\ntimezone: Asia/Ho_Chi_Minh\n"
        )
        _, messages = parse(raw)
        self.assertEqual(messages, [])

    def test_anchor_containers_are_ignored(self) -> None:
        raw = loads(
            "name: anchored\n"
            "x-base: &base\n"
            "  update: true\n"
            "  packages: [git, jq]\n"
            "apt:\n"
            "  <<: *base\n"
        )
        profile, messages = parse(raw)
        self.assertEqual(messages, [])
        self.assertEqual(profile.apt_packages, ["git", "jq"])
        variables = render.render_vars(profile, Path("x.yml"))
        self.assertIn("gen_apt_packages:\n- git\n- jq\n", variables)
        self.assertNotIn("x-base", variables)
        self.assertNotIn("x-base", render.render_cloud_init(profile, Path("x.yml")))

    def test_explicit_keys_override_merged_values(self) -> None:
        raw = loads(
            "name: merged\n"
            "<<: &defaults\n"
            "  timezone: UTC\n"
            "  locale: en_US.UTF-8\n"
            "timezone: Asia/Ho_Chi_Minh\n"
        )
        profile, _ = parse(raw)
        self.assertEqual(profile.timezone, "Asia/Ho_Chi_Minh")
        self.assertEqual(profile.locale, "en_US.UTF-8")


class ListRuleTest(unittest.TestCase):
    """List rules the schema states and the renderer enforces."""

    def test_empty_repository_components_are_rejected(self) -> None:
        _, messages = parse(
            {
                "name": "t",
                "apt": {
                    "repositories": [
                        {
                            "name": "cli",
                            "uri": "https://example.invalid/packages",
                            "suite": "stable",
                            "components": [],
                        }
                    ]
                },
            }
        )
        self.assertTrue(
            any("at least one component" in message for message in messages)
        )

    def test_duplicates_collapse_preserving_order(self) -> None:
        profile, messages = parse(
            {
                "name": "t",
                "apt": {"packages": ["jq", "git", "jq"]},
                "python": {"uv_tools": ["ruff", "ruff", "mypy"]},
            }
        )
        self.assertEqual(messages, [])
        self.assertEqual(profile.apt_packages, ["jq", "git"])
        self.assertEqual(profile.uv_tools, ["ruff", "mypy"])


class EnvFileTest(unittest.TestCase):
    """The env file is a systemd EnvironmentFile first, shell-sourced second."""

    def env_content(self, env: dict[str, str]) -> str:
        """Returns the rendered /etc/runner-env.sh content."""
        profile, messages = parse({"name": "t", "env": env})
        self.assertEqual(messages, [])
        files = render.build_write_files(profile)
        return next(
            str(entry["content"])
            for entry in files
            if entry["path"] == "/etc/runner-env.sh"
        )

    def test_env_file_lines_are_key_value_assignments(self) -> None:
        """`export ` would make systemd read the whole prefix as the name."""
        content = self.env_content({"MY_VAR": "plain", "QUOTED": "it's"})

        self.assertNotIn("export ", content)
        # prepare.yml writes the same two header lines, so the first `prepare`
        # after `create` must not report a change.
        self.assertTrue(
            content.startswith(
                "# Read by the runner's systemd unit. Not a secret store: this file is\n"
                "# readable by the runner's group and baked into the container image.\n"
            )
        )
        for line in content.splitlines():
            if not line or line.startswith("#"):
                continue
            self.assertRegex(line, r'^[A-Za-z_][A-Za-z0-9_]*=".*"$')
        self.assertIn('MY_VAR="plain"\n', content)
        self.assertIn("QUOTED=\"it's\"\n", content)

    def test_env_file_values_survive_bash_sourcing(self) -> None:
        """Quotes, a dollar sign, a backslash and a backtick come back verbatim."""
        env = {
            "BOTH_QUOTES": "it's \"quoted\"",
            "HOME_REF": "keep $HOME literal",
            "BACKSLASH": "C:\\temp\\x",
            "BACKTICK": "run `date` now",
        }
        content = self.env_content(env)
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "runner-env.sh"
            path.write_text(content, encoding="utf-8")
            result = subprocess.run(
                [
                    "bash",
                    "-c",
                    'set -a; . "$1"; printf "%s\\n" "$BOTH_QUOTES" "$HOME_REF" "$BACKSLASH" "$BACKTICK"',
                    "_",
                    str(path),
                ],
                capture_output=True,
                text=True,
                check=True,
            )

        self.assertEqual(
            result.stdout.splitlines(),
            [
                "it's \"quoted\"",
                "keep $HOME literal",
                "C:\\temp\\x",
                "run `date` now",
            ],
        )


class ReservedEnvNameTest(unittest.TestCase):
    """The wrapper owns GH_* and the names bash itself reads."""

    def test_reserved_env_keys_are_rejected(self) -> None:
        reserved = (
            "GH_HOST",
            "GH_TOKEN",
            "LD_AUDIT",
            "PATH",
            "HOME",
            "IFS",
            "PYTHONPATH",
        )
        for key in reserved:
            with self.subTest(key=key):
                _, messages = parse({"name": "t", "env": {key: "x"}})
                self.assertTrue(
                    any(
                        message.endswith(
                            f"env.{key}: reserved name; the runner wrapper owns it"
                        )
                        for message in messages
                    ),
                    messages,
                )

    def test_schema_rejects_reserved_env_keys(self) -> None:
        check = validator()
        for key in ("GH_HOST", "LD_AUDIT", "PATH"):
            with self.subTest(key=key):
                self.assertTrue(
                    list(check.iter_errors({"name": "x", "env": {key: "y"}}))
                )
        self.assertEqual(
            list(check.iter_errors({"name": "x", "env": {"APP_HOST": "y"}})), []
        )


class InjectedPackageTest(unittest.TestCase):
    """cloud-init installs what its own wiring needs before Ansible runs."""

    def test_locale_and_timezone_tooling_is_injected(self) -> None:
        profile, messages = parse(
            {"name": "t", "locale": "en_US.UTF-8", "timezone": "UTC"}
        )
        self.assertEqual(messages, [])

        block = render.build_packages_block(profile)

        self.assertIn("# added by render.py because locale is set\n- locales", block)
        self.assertIn("# added by render.py because timezone is set\n- tzdata", block)
        # prepare.yml installs them itself, so gen_service_packages stays clean.
        self.assertEqual(render.service_package_names(profile), [])


class ProfileNameTest(unittest.TestCase):
    """The name is an Incus profile name, so it follows the Incus rules."""

    def test_trailing_hyphen_is_rejected(self) -> None:
        _, messages = parse({"name": "my-kit-"})

        self.assertTrue(any("must match ^[a-z0-9]" in m for m in messages), messages)

    def test_name_is_limited_to_60_characters(self) -> None:
        """60 leaves room for -1/-2 inside Incus's 63-character instance name."""
        _, messages = parse({"name": "a" * 60})
        self.assertEqual(messages, [])

        _, messages = parse({"name": "a" * 61})
        self.assertTrue(any("must match ^[a-z0-9]" in m for m in messages), messages)


class RedisSocketDirTest(unittest.TestCase):
    """The runtime directory comes from the socket path, not a constant."""

    def test_runtime_directory_follows_the_socket(self) -> None:
        profile, messages = parse(
            {
                "name": "t",
                "services": {"redis": {"unixsocket": "/var/run/app/redis.sock"}},
            }
        )
        self.assertEqual(messages, [])

        lines = render.redis_block_lines(profile)

        self.assertIn('redis_dir="$(dirname /var/run/app/redis.sock)"', lines)
        self.assertIn(
            '[ -d "$redis_dir" ] || install -d -o redis -g redis -m 0775 "$redis_dir"',
            lines,
        )


if __name__ == "__main__":
    unittest.main()
