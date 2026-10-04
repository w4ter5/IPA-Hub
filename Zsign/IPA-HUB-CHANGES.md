# Zsign in IPA Hub

Sources copied from https://github.com/khcrysalis/Zsign-Package (branch `package`,
commit c4ba9da), MIT License — see `LICENSE`. Only the files needed by the Swift
package are kept (no prebuilt Windows binaries or tests).

Local change:

- `src/bundle.cpp`: `embedded.mobileprovision` was always deleted while sealing the
  main bundle, because the "keep profile" flag had opposite meanings in two places.
  Signed apps came out without a provisioning profile and could not be installed.
  The profile is now kept unless "Remove provisioning file" is enabled in Feather.
