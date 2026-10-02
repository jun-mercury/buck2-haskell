#!/usr/bin/env python3

"""Wrapper for ghc-pkg register
"""

import argparse

from ghc_pkg import register

def main():
    parser = argparse.ArgumentParser(description=__doc__)

    parser.add_argument(
        "--ghc-pkg",
        required=True,
        type=str,
        help="Path to ghc-pkg",
    )
    parser.add_argument(
        "--output",
        required=True,
        type=str,
        help="Output DB path",
    )
    parser.add_argument(
        "--package-conf",
        required=True,
        type=str,
        help="package.conf source",
    )

    args = parser.parse_args()

    register(args.ghc_pkg, args.output, args.package_conf)

if __name__ == "__main__":
    main()
