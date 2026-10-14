#!/usr/bin/python3
"""Fixture hook: reads its event name from argv."""
import sys
print("notify", sys.argv[1:])
