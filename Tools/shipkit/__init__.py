"""ship — walk an Xcode app from a clean checkout to a TestFlight build.

Stdlib only, on purpose. Anything that needs installing is a step between the
maintainer and a release, and the whole point of this tool is that there are
fewer of those. The one external dependency is the machine's own Apple
toolchain, which a release could not happen without anyway.
"""

__version__ = "0.1.0"
