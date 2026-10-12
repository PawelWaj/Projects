// Stages to add to the migration repository's Jenkins pipeline. One run per changed flow module.
// Parameters: FLOW (flow name), MODULE (module dir), TARGET (target branch, default main),
//             IMPLEMENTER_ID (git author e-mail used by the implementer agent).
pipeline {
  agent { label 'maven-docker' }          // Java 21, Maven 3.9, Python 3, Docker or Podman for Testcontainers
  parameters {
    string(name: 'FLOW', description: 'OSB flow name, e.g. order-event')
    string(name: 'MODULE', description: 'Maven module directory of the flow')
    string(name: 'TARGET', defaultValue: 'main')
    string(name: 'IMPLEMENTER_ID', defaultValue: 'implementer-agent@ci.local')
  }
  stages {
    stage('guard') {
      // Independence rule: the implementer identity may not touch tests, fixtures or the manifest.
      steps {
        sh '''
          set -eu
          git fetch -q origin "$TARGET"
          BAD=""
          for c in $(git rev-list "origin/$TARGET..HEAD"); do
            if [ "$(git show -s --format=%ae "$c")" = "$IMPLEMENTER_ID" ]; then
              F=$(git show --name-only --format= "$c" | grep -E '/src/test/|/golden/|/parity/|MANIFEST\\.csv' || true)
              [ -n "$F" ] && BAD="$BAD $c"
            fi
          done
          if [ -n "$BAD" ]; then echo "Implementer commits touch test paths:$BAD"; exit 1; fi
        '''
      }
    }
    stage('approved card') {
      steps {
        sh 'grep -Eq "^\\| \\*\\*Status\\*\\* \\| approved" "migration/$FLOW/FLOW_CARD.md" || { echo "card not approved"; exit 1; }'
      }
    }
    stage('gates G1-G8') {
      steps { sh 'tools/verify_flow.sh "$MODULE" "$FLOW"' }
    }
  }
  post {
    always {
      archiveArtifacts artifacts: "migration/${params.FLOW}/**, ${params.MODULE}/target/*-reports/**", allowEmptyArchive: true
      junit testResults: "${params.MODULE}/target/*-reports/TEST-*.xml", allowEmptyResults: true
    }
  }
}
