import base64
import os
from pathlib import Path
import subprocess
import shutil
import tempfile
import unittest


class UpdateKeyTests(unittest.TestCase):
    def test_first_build_emits_only_public_key_and_reuses_it(self):
        script = Path(__file__).parents[1] / "ensure_update_signing_key.sh"
        public_key = base64.b64encode(bytes(32)).decode()
        with tempfile.TemporaryDirectory() as directory:
            tools = Path(directory)
            fixture_script = tools / "project/scripts/ensure_update_signing_key.sh"
            fixture_script.parent.mkdir(parents=True)
            shutil.copyfile(script, fixture_script)
            fake = tools / "generate_keys"
            fake.write_text(f'''#!/bin/zsh
marker="${{0:A:h}}/created"
if [[ "$*" == *-p ]]; then
  if [[ ! -f "$marker" ]]; then
    print 'ERROR: No existing signing key found!'
    exit 1
  fi
  print '{public_key}'
else
  [[ ! -f "$marker" ]] || exit 2
  touch "$marker"
  print 'Generated fixture key'
fi
''')
            fake.chmod(0o755)
            env = dict(os.environ, PASTEORY_SPARKLE_TOOLS=directory)
            env.pop("PASTEORY_UPDATE_PUBLIC_KEY", None)
            first = subprocess.run(["zsh", str(fixture_script)], env=env, check=True, capture_output=True, text=True)
            second = subprocess.run(["zsh", str(fixture_script)], env=env, check=True, capture_output=True, text=True)
            self.assertEqual(first.stdout.strip(), public_key)
            self.assertEqual(second.stdout.strip(), public_key)
            self.assertIn("Generated fixture key", first.stderr)
            self.assertNotIn("Generated fixture key", second.stderr)


if __name__ == "__main__":
    unittest.main()
