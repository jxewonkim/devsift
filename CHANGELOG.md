# Changelog

All notable changes to DevSift will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project follows [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- Initial product scope, safety model, privacy contract, architecture, and
  development plan.
- Swift package foundations for DevSiftCore, the `devsift` CLI, and the DevSift
  SwiftUI app.
- Continuous integration for formatting, debug and release builds, and tests.
- A read-only, cancellable allocated-size scanner with descriptor-anchored
  traversal, deterministic bounded reports, structured partial errors,
  cross-volume pruning, and conservative hard-link accounting.
- A dependency-free `devsift scan <path>` command with deterministic,
  terminal-safe text output, versioned root-relative JSON, explicit partial
  results, stable exit codes, and synthetic executable integration tests.
- A native read-only scan dashboard with explicit folder selection,
  cancellable scans, complete and partial result presentation, accessible
  keyboard controls, and light and dark appearance support.
- Explicit per-summary size-overflow state so frontends do not present a
  saturated size as an exact observation.
- JSON scan schema version 2, adding the per-summary `sizeOverflowed` flag;
  text output now withholds overflowed totals instead of formatting saturation
  as an exact byte count.
