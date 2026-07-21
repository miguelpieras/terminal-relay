# Terminal Relay delivery instructions

After every user-requested change to this repository, run `./Scripts/build-and-install.sh` before reporting completion. The command must regenerate the Xcode project, pass all tests, build the Release app, install it at `/Applications/Terminal Relay.app`, and relaunch it.

Do not report a requested change as complete when this command fails. Keep the installed application path stable so its Dock item always opens the newest successful build.
