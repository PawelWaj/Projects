# Settings for running the flows of this folder locally. Edit once; read by run.sh and every <project>/run-local.sh.
# Values already set in the shell win. No passwords here: export BROKER_PASSWORD in the window where you run.

# Java 21 (Git Bash path). Empty = the java on the PATH.
export JAVA_HOME="${JAVA_HOME:-}"
[ -n "$JAVA_HOME" ] && export PATH="$JAVA_HOME/bin:$PATH"

# Maven with access to the Maven repository (Nexus). JBang, Camel, Saxon and the Artemis client are downloaded
# through it when JBang / the camel CLI are not installed. Empty = Maven's default ~/.m2/settings.xml.
export MVN_ARGS="${MVN_ARGS:-}"

# Apache Artemis: the unzipped distribution, and the local broker instance (bash run.sh setup-broker creates it).
_D=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)       # this folder, whichever folder the script is called from
export ARTEMIS_HOME="${ARTEMIS_HOME:-$(ls -d "$_D"/../apache-artemis-* /c/tools/apache-artemis-* "$HOME"/apache-artemis-* 2>/dev/null | head -1)}"
export ARTEMIS_BROKER="${ARTEMIS_BROKER:-$HOME/artemis-broker}"

# Broker connection of the routes and of the test scripts (core protocol).
export BROKER_URL="${BROKER_URL:-tcp://localhost:61616}"
export BROKER_USER="${BROKER_USER:-artemis}"
# export BROKER_PASSWORD=...        <- in the window, never in this file

# Camel version of camel run (the routes and the tests are built for it).
export CAMEL_VERSION="${CAMEL_VERSION:-4.18.4}"
