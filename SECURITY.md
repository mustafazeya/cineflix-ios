# Security policy

## Supported versions

Security fixes go into the latest release and the `main` branch.

## Reporting a vulnerability

**Please do not open a public issue for a security problem.**

Report it privately through GitHub: open the **Security** tab of this repository and choose **Report a vulnerability**
(or go to `https://github.com/mustafazeya/cineflix-ios/security/advisories/new`).

Please include what you found, the steps to reproduce it, the affected version or commit, and the impact you expect.
You can expect an acknowledgement within a few days and a fix or an explanation as soon as it can be prepared.
Please give a reasonable time to fix the issue before you disclose it publicly. Credit is given in the release notes unless you prefer not.

## Scope

In scope: the app code and scripts in this repository.
Out of scope: vulnerabilities in iOS, TMDB, SubDL, YouTube or your own media server.

## Notes for users

- Keys in `Config/Secrets.xcconfig` are bundled into the app's `Info.plist` and can be read by whoever has the build. Do not distribute builds made with your keys.
- The app allows plain `http://` connections so it can reach a server on your local network. Serve anything on the internet over HTTPS.
- Treat TMDB and SubDL keys as secrets. If one leaks, revoke it in the provider's dashboard and create a new one.
