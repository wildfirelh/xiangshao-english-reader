"""Create a local release identity once, without printing or embedding passwords."""
import argparse
import os
from pathlib import Path
import secrets
import subprocess

ROOT = Path(__file__).resolve().parents[1]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--keytool', default='keytool')
    args = parser.parse_args()
    config = ROOT / 'android/key.properties'
    keystore = ROOT / 'android/release-signing/xiangshao-release.jks'
    if config.exists() or keystore.exists():
        raise SystemExit('Signing files already exist; keep them for future updates. No files changed.')
    keystore.parent.mkdir(parents=True, exist_ok=True)
    password = secrets.token_urlsafe(36)
    env = dict(os.environ, TEXTBOOK_KEY_PASSWORD=password)
    subprocess.run([
        args.keytool, '-genkeypair', '-keystore', str(keystore), '-storetype', 'JKS',
        '-alias', 'xiangshao-release', '-keyalg', 'RSA', '-keysize', '3072',
        '-validity', '10000', '-dname', 'CN=Xiangshao Point Reading',
        '-storepass:env', 'TEXTBOOK_KEY_PASSWORD',
        '-keypass:env', 'TEXTBOOK_KEY_PASSWORD', '-noprompt',
    ], env=env, check=True, capture_output=True)
    with config.open('x', encoding='utf-8', newline='\n') as output:
        output.write('storeFile=release-signing/xiangshao-release.jks\n'
                     'keyAlias=xiangshao-release\n'
                     f'storePassword={password}\nkeyPassword={password}\n')
    print(f'Created release keystore: {keystore}')
    print(f'Created private signing configuration: {config}')
    print('Back up both files together. They are excluded from version control.')


if __name__ == '__main__':
    main()
