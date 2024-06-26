#!/usr/bin/env python3

import sys
import os
import stat

if len(sys.argv) != 3:
    print("Usage: generate-connections.py origin-file destination-file")
    sys.exit(1)

origin = sys.argv[1]
destination = sys.argv[2]

if not os.path.isfile(origin):
    sys.exit(0)

destination_dir = os.path.dirname(destination)
if not os.path.exists(destination_dir):
    os.makedirs(destination_dir)

with open(origin, "rt") as origin_data:
    with open(destination, "wt") as destination_data:
        destination_data.write("""#!/bin/sh

while : ; do
    retval=0
""")
        for line in origin_data.readlines():
            line = line.strip()
            if line == "":
                continue
            if line[0] == '#':
                continue
            snap_name = line[:line.find(":")]
            destination_data.write(f"""
    echo Connecting {line}
    if /usr/bin/snap list {snap_name}; then
        if ! /usr/bin/snap connect {line}; then
            retval=1
        fi
    else
        retval=1
    fi
""")
        destination_data.write("""
    if [ "$retval" = "0" ] ; then
        systemctl disable manual-plug-connection.service
        exit 0
    fi
    sleep 1
done
""")

os.chmod(destination, 0o755)
