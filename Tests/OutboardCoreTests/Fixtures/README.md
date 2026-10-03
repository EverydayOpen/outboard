# Core test fixtures

Read from disk with `#filePath` (never bundled, so Linux builds stay warning-free). The probe workflow (`fixtures.yml`, day 1,
weekly) records the real command output of `diskutil info -plist`, `diskutil list -plist`, `diskutil apfs list -plist` and
`tmutil destinationinfo -X` on the CI runners; those files land in `commands/` and become parser fixtures. Nothing here is
a measurement from a real USB or Thunderbolt drive until a tester contributes one.

Any fake secret or token a fixture needs is built from pieces at runtime (GitHub push protection blocks key-shaped literals).
