# Supertester v0.2.0 - Release Commands

## Verification Commands

```bash
# Compile with strict warnings
mix compile --warnings-as-errors

# Run all tests
mix test

# Generate documentation
mix docs

# Build hex package
mix hex.build

# View documentation locally
open doc/index.html
```

## Publication Commands

```bash
# 1. Verify everything is ready
mix test && mix compile --warnings-as-errors && mix docs

# 2. Publish to hex.pm
mix hex.publish

# 3. Git tag and push
git tag v0.2.0
git push origin master
git push origin v0.2.0

# 4. Create GitHub release (optional)
gh release create v0.2.0 \
  --title "v0.2.0 - Chaos Engineering & Performance Testing" \
  --notes "See CHANGELOG.md for details" \
  supertester-0.2.0.tar
```

## Verification Results

```
✅ Compilation: PASS (zero warnings)
✅ Tests: 37 passing, 0 failures, 2 skipped
✅ Documentation: Generated successfully
✅ Hex Package: Built successfully (32KB)
✅ Version: 0.2.0
✅ Quality: Production-ready
```

## Post-Publication

```bash
# Verify on hex.pm
open https://hex.pm/packages/supertester

# View published docs
open https://hexdocs.pm/supertester
```
