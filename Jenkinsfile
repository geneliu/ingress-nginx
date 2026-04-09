// Patch / CVE rebuild pipeline: controller image + Helm chart OCI only.
// Local laptops: use Makefile `local-patch-artifacts` with Podman (SKIP_PUSH); set DOCKER/RUNTIME env here if agents use Podman.
// Same scope as dockerhub-publish.yaml, not full upstream multi-arch release or e2e.
//
// Prerequisites on agents: git, docker, make, curl; Go runs inside make's dockerized build.
// Jenkins credentials: create Username/Password id "registry-ingress-nginx" (or change id below).
//
// Multibranch: tag builds set TAG_NAME; script prefers CI_IMAGE_TAG then TAG_NAME then TAG file.
//
// GitLab: mirror this repo to GitLab; Jenkins can poll GitLab or use a GitLab webhook to Jenkins.
//
// Corporate HTTP(S) proxy: set on the job or agent (recommended), for example:
//   HTTP_PROXY  = http://proxy.example.corp:8080
//   HTTPS_PROXY = http://proxy.example.corp:8080
//   NO_PROXY    = localhost,127.0.0.1,.corp,registry.internal
// (Lowercase http_proxy / https_proxy / no_proxy also work; the script normalizes both.)
// The Docker daemon on the agent may still need its own proxy config for docker pull/push.

pipeline {
  // Use a label that matches your agents, or `any` if Docker is always available.
  agent { label 'docker && linux' }

  options {
    timestamps()
    disableConcurrentBuilds()
  }

  parameters {
    string(name: 'REGISTRY', defaultValue: '', description: 'Required unless set as job env. e.g. docker.io/myorg or registry.gitlab.com/group/project')
    string(name: 'CI_IMAGE_TAG', defaultValue: '', description: 'Optional. Empty = Git tag (Multibranch) or repo TAG file')
    booleanParam(name: 'SKIP_HELM', defaultValue: false, description: 'Skip Helm chart package and OCI push')
    booleanParam(name: 'SKIP_TRIVY', defaultValue: false, description: 'Skip Trivy scan if installed')
  }

  environment {
    ARCH = 'amd64'
  }

  stages {
    stage('Checkout') {
      steps {
        checkout scm
      }
    }

    stage('Publish controller + chart') {
      steps {
        script {
          def reg = params.REGISTRY?.trim() ?: env.REGISTRY?.trim()
          if (!reg) {
            error('Set pipeline parameter REGISTRY or job environment REGISTRY')
          }
          env.REGISTRY = reg
        }
        withCredentials([usernamePassword(credentialsId: 'registry-ingress-nginx', usernameVariable: 'REGISTRY_USER', passwordVariable: 'REGISTRY_PASSWORD')]) {
          sh '''
            export REGISTRY="${REGISTRY}"
            export CI_IMAGE_TAG="${CI_IMAGE_TAG}"
            export SKIP_HELM="${SKIP_HELM}"
            export SKIP_TRIVY="${SKIP_TRIVY}"
            export COMMIT_SHA="git-$(git rev-parse --short HEAD)"
            export BUILD_ID="jenkins-${BUILD_NUMBER}"
            bash hack/ci/jenkins-controller-publish.sh
          '''
        }
      }
    }
  }
}
