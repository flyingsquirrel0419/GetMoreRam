# Get More Ram
A simple [StosSign](https://github.com/stossy11/StosSign) wrapper app that allows you to enable "Increased Memory Limit" for your sideloaded apps without using Xcode.

# How to use
1. Sideload this app
2. Go to settings, sign in your account that you used to sign the app you want to enable "Increased Memory Limit"
3. Go to "App IDs" page
4. Tap Refresh
5. Tap the app you want to enable "Increased Memory Limit"
6. Tap "Add Increased Memory Limit"
7. Reinstall the app from SideStore/AltStore
8. Check if you have "Increased Memory Limit"

# Credits
Stossy11 - For StosSign.
SideStore - Anisette Data fetching codes are stolen from SideStore

## On-device Anisette
Settings defaults to **On-Device Anisette**, powered by the same
[AnisetteKit](https://github.com/mahee96/AnisetteKit) Unicorn TCI provider used by
SideStore. No JIT is needed. First use downloads the ADI libraries from SideStore's
default ODA metadata source (`https://zzz.haus/oda.json`) and verifies their archive
checksum; generation then runs on device. Apple provisioning still needs internet.
Local and remote provisioning blobs are stored separately in Keychain.

**Reset adi.pb** clears both provisioning stores and signs out, preserving signing
certificates. **Keep header customizations** defaults to on. Disabling it restores
the current SideStore client identity defaults. Anisette and Apple sign-in headers
are editable independently. Switching providers does not reuse the other provider's blob.

Additional dependencies: [AnisetteKit (AGPL-3.0)](https://github.com/mahee96/AnisetteKit/blob/main/LICENSE),
[ZIPFoundation (MIT)](https://github.com/weichsel/ZIPFoundation/blob/development/LICENSE).
