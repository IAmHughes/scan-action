#!/bin/bash

set -eo pipefail

export scriptname_arg=$1
export inline_scan_image_arg=$2
export image_reference_arg=$3
export debug=$4
export anchore_policy_bundle_path_arg=$5
export anchore_policy_bundle_name_arg=$6
export dockerfile_path_arg=$7

export IMAGE_DIGEST_SHA="sha256:0a97ccb2868e3c54167317fe7a2fc58e5123290d6c5b653a725091cbf18ca1ea"
export SCANOPTS="-r http://localhost:8228/v1 -u admin -p foobar -d ${IMAGE_DIGEST_SHA}"
export CLIOPTS="--json"
export ANCHORE_CI_IMAGE="${inline_scan_image_arg}"
export SCAN_SCRIPT="${scriptname_arg}"
export ANCHORE_LOG=./anchore-reports/run.log

trap 'debug' EXIT ERR SIGTERM
debug() {
    if [[ "${debug}" = "true" ]]; then
        cat "${ANCHORE_LOG}"
    fi
}

mkdir -p ./anchore-reports/

if [[ "${debug}" = "true" ]]; then
    CLIOPTS="${CLIOPTS} --debug"
    SCANOPTS="${SCANOPTS} -V"
    set -x
fi

# make sure the actual scan script is available
if ! hash "${SCAN_SCRIPT}"; then
   echo "ERROR: cannot locate executable scan script ${SCAN_SCRIPT}" >> "${ANCHORE_LOG}" 2>&1
   exit 1
fi

# make sure the image to be scanned is available and try pulling if not
if ! docker inspect "${image_reference_arg}" >> "${ANCHORE_LOG}" 2>&1; then
    docker pull "${image_reference_arg}" >> "${ANCHORE_LOG}" 2>&1
    if ! docker inspect "${image_reference_arg}" >> "${ANCHORE_LOG}" 2>&1; then
        echo "ERROR: cannot locate local or remote image ${image_reference_arg}" >> "${ANCHORE_LOG}" 2>&1
        exit 1
    fi
fi

# make sure the anchore inline scan image is available
docker pull "${ANCHORE_CI_IMAGE}" >> "${ANCHORE_LOG}" 2>&1
if ! docker inspect "${ANCHORE_CI_IMAGE}" >> "${ANCHORE_LOG}" 2>&1; then
    echo "ERROR: cannot locate local or remote image ${ANCHORE_CI_IMAGE}" >> "${ANCHORE_LOG}" 2>&1
    exit 1
fi

# start up the inline scan image
docker run -d -p 8228:8228 --name local-anchore-engine "${ANCHORE_CI_IMAGE}" start >> "${ANCHORE_LOG}" 2>&1
docker exec -t local-anchore-engine anchore-cli ${CLIOPTS} system wait --timeout 60 --interval 1.0 >> "${ANCHORE_LOG}" 2>&1
docker cp "${anchore_policy_bundle_path_arg}" local-anchore-engine:/tmp/anchore-policy-bundle.json >> "${ANCHORE_LOG}" 2>&1
docker exec -t local-anchore-engine anchore-cli ${CLIOPTS} policy add /tmp/anchore-policy-bundle.json >> "${ANCHORE_LOG}" 2>&1
docker exec -t local-anchore-engine anchore-cli policy activate "${anchore_policy_bundle_name_arg}" >> "${ANCHORE_LOG}" 2>&1
# setup scan script CLI 

# for 'scan' op
#OPTS="-r"
#if [ ! -z "${dockerfile_path_arg}" ]; then
#    OPTS="${OPTS} -d ${dockerfile_path_arg}"
#fi
## perform the scan callout
#${SCAN_SCRIPT} scan ${OPTS} ${image_reference_arg}

# for 'analyze' op - use fixed digest here, doesn't matter

if [[ -n "${dockerfile_path_arg}" ]]; then
    SCANOPTS="${SCANOPTS} -f ${dockerfile_path_arg}"
fi

# perform the scan callout
"${SCAN_SCRIPT}" analyze ${SCANOPTS} "${image_reference_arg}" >> "${ANCHORE_LOG}" 2>&1
export ANALYZE_RC=$?

echo ""
# docker exec -t local-anchore-engine anchore-cli image get ${IMAGE_DIGEST_SHA}
echo "--------- Anchore Policy Evaluation ---------"
set +eo pipefail
docker exec -t local-anchore-engine anchore-cli evaluate check --detail "${IMAGE_DIGEST_SHA}" --tag "${image_reference_arg}" --policy "${anchore_policy_bundle_name_arg}"
docker exec -t local-anchore-engine anchore-cli --json evaluate check --detail "${IMAGE_DIGEST_SHA}" --tag "${image_reference_arg}" --policy "${anchore_policy_bundle_name_arg}" > ./anchore-reports/policy_evaluation.json
set -eo pipefail
docker exec -t local-anchore-engine anchore-cli --json image vuln "${IMAGE_DIGEST_SHA}" all > ./anchore-reports/vulnerabilities.json
docker exec -t local-anchore-engine anchore-cli --json image content "${IMAGE_DIGEST_SHA}" os > ./anchore-reports/content-os.json
docker exec -t local-anchore-engine anchore-cli --json image content "${IMAGE_DIGEST_SHA}" java > ./anchore-reports/content-java.json
docker exec -t local-anchore-engine anchore-cli --json image content "${IMAGE_DIGEST_SHA}" gem > ./anchore-reports/content-gem.json
docker exec -t local-anchore-engine anchore-cli --json image content "${IMAGE_DIGEST_SHA}" python > ./anchore-reports/content-python.json
docker exec -t local-anchore-engine anchore-cli --json image content "${IMAGE_DIGEST_SHA}" npm > ./anchore-reports/content-npm.json
echo ""

if [[ "${debug}" = "true" ]]; then
    mkdir -p ./anchore-reports/anchore-engine-logs
    docker cp local-anchore-engine:/var/log/anchore/ ./anchore-reports/anchore-engine-logs/
fi

docker stop local-anchore-engine >> "${ANCHORE_LOG}" 2>&1
docker rm local-anchore-engine >> "${ANCHORE_LOG}" 2>&1

exit "${ANALYZE_RC}"
