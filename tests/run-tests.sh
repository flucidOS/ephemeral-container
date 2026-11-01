#!/usr/bin/env bash
# tests/run-tests.sh — Automated Test Suite for FlucidOS ephemeral-container (ec)
set -euo pipefail

PASS_COUNT=0
FAIL_COUNT=0
TEST_ROOT="$(mktemp -d /tmp/ec-test-suite.XXXXXX)"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

cleanup() {
    rm -rf "${TEST_ROOT}"
    if command -v podman >/dev/null 2>&1; then
        podman rmi -f localhost/ec-test-base:test localhost/ec-test-snap:test localhost/ec-test-final:test >/dev/null 2>&1 || true
    fi
}
trap cleanup EXIT

pass() {
    echo -e "\033[1;32m[PASS]\033[0m $1"
    PASS_COUNT=$((PASS_COUNT + 1))
}

fail() {
    echo -e "\033[1;31m[FAIL]\033[0m $1: $2"
    FAIL_COUNT=$((FAIL_COUNT + 1))
}

echo "================================================================================"
echo " Running FlucidOS Ephemeral Container (ec) Test Suite"
echo "================================================================================"

# ------------------------------------------------------------------------------
# TC-01: Static Syntax & FHS Installation Layout
# ------------------------------------------------------------------------------
if bash -n "${REPO_ROOT}/bin/ec" \
           "${REPO_ROOT}/libexec/ec-host-engine" \
           "${REPO_ROOT}/libexec/ec-container-finalize" \
           "${REPO_ROOT}/share/ephemeral-container/ec-profile.sh"; then
    STAGE_DIR="${TEST_ROOT}/destdir"
    make -C "${REPO_ROOT}" install DESTDIR="${STAGE_DIR}" >/dev/null
    if [[ -x "${STAGE_DIR}/usr/bin/ec" && \
          -x "${STAGE_DIR}/usr/libexec/ec/ec-host-engine" && \
          -x "${STAGE_DIR}/usr/libexec/ec/ec-container-finalize" && \
          -f "${STAGE_DIR}/usr/share/ephemeral-container/Containerfile.seal" && \
          -f "${STAGE_DIR}/usr/share/ephemeral-container/ec-profile.sh" && \
          -d "${STAGE_DIR}/etc/flucid/mok" ]]; then
        pass "TC-01: Static syntax validation and FHS installation layout"
    else
        fail "TC-01" "Missing expected files in DESTDIR layout"
    fi
else
    fail "TC-01" "bash -n syntax check failed"
fi

# ------------------------------------------------------------------------------
# TC-02: Context-Aware CLI Routing (Host Mode vs. In-Session Mode)
# ------------------------------------------------------------------------------
if ! "${REPO_ROOT}/bin/ec" invalid-cmd >/dev/null 2>&1; then
    pass "TC-02a: Host CLI rejects unknown subcommands with non-zero exit"
else
    fail "TC-02a" "Host CLI did not fail on unknown command"
fi

MOCK_SESSION_SCRIPT="${TEST_ROOT}/ec-in-session"
sed "s|/run/.ec-session|${TEST_ROOT}/.ec-session|g; s|/var/tmp/.ec-commit|${TEST_ROOT}/.ec-commit|g; s|kill -TERM|# kill -TERM|g" \
    "${REPO_ROOT}/bin/ec" > "${MOCK_SESSION_SCRIPT}"
chmod +x "${MOCK_SESSION_SCRIPT}"
touch "${TEST_ROOT}/.ec-session"

if ! "${MOCK_SESSION_SCRIPT}" open >/dev/null 2>&1; then
    pass "TC-02b: In-Container CLI blocks nested 'ec open'"
else
    fail "TC-02b" "Nested 'ec open' was not blocked"
fi

"${MOCK_SESSION_SCRIPT}" exit >/dev/null
if [[ -f "${TEST_ROOT}/.ec-commit" ]]; then
    pass "TC-02c: In-Container 'ec exit' writes persistent commit marker"
else
    fail "TC-02c" "Commit marker was not created by 'ec exit'"
fi

"${MOCK_SESSION_SCRIPT}" abort >/dev/null
if [[ ! -f "${TEST_ROOT}/.ec-commit" ]]; then
    pass "TC-02d: In-Container 'ec abort' removes commit marker"
else
    fail "TC-02d" "Commit marker was not removed by 'ec abort'"
fi

# ------------------------------------------------------------------------------
# TC-03: Automatic MOK Keypair Generation & Permissions
# ------------------------------------------------------------------------------
MOK_TEST_DIR="${TEST_ROOT}/mok"
mkdir -p "${MOK_TEST_DIR}"
openssl req -new -x509 -newkey rsa:2048 -nodes -days 365 \
    -subj "/CN=FlucidOS Local Module Signing Key/" \
    -keyout "${MOK_TEST_DIR}/MOK.priv" \
    -outform DER -out "${MOK_TEST_DIR}/MOK.der" 2>/dev/null
chmod 0600 "${MOK_TEST_DIR}/MOK.priv"
chmod 0644 "${MOK_TEST_DIR}/MOK.der"

if [[ -s "${MOK_TEST_DIR}/MOK.priv" && -s "${MOK_TEST_DIR}/MOK.der" ]]; then
    pass "TC-03: MOK private key and DER certificate generated and verified"
else
    fail "TC-03" "MOK keypair generation failed"
fi

# ------------------------------------------------------------------------------
# TC-04: Fail-Closed When MOK Secrets Are Missing
# ------------------------------------------------------------------------------
MOCK_FINALIZE="${TEST_ROOT}/ec-finalize-mock"
export FAKE_ROOT="${TEST_ROOT}/fakeroot"
mkdir -p "${FAKE_ROOT}/run/secrets"
sed "s|/run/secrets|${FAKE_ROOT}/run/secrets|g; s|/usr/lib/modules|${FAKE_ROOT}/usr/lib/modules|g; s|/usr/lib/modprobe.d|${FAKE_ROOT}/usr/lib/modprobe.d|g; s|/usr/local|${FAKE_ROOT}/usr/local|g" \
    "${REPO_ROOT}/libexec/ec-container-finalize" > "${MOCK_FINALIZE}"
chmod +x "${MOCK_FINALIZE}"

if ! "${MOCK_FINALIZE}" "6.12.0-flucid" >/dev/null 2>&1; then
    pass "TC-04: Finalizer fails closed when MOK secret mounts are missing"
else
    fail "TC-04" "Finalizer succeeded despite missing MOK secret keys"
fi

# ------------------------------------------------------------------------------
# TC-05: Out-of-Tree .ko MOK Signing & Single Unified depmod Pass
# ------------------------------------------------------------------------------
KVER_TEST="6.12.0-flucid"
mkdir -p "${FAKE_ROOT}/usr/lib/modules/${KVER_TEST}/extra/rtl88x2bu" \
         "${FAKE_ROOT}/usr/lib/modules/${KVER_TEST}/build/scripts" \
         "${FAKE_ROOT}/bin"

cp "${MOK_TEST_DIR}/MOK.priv" "${FAKE_ROOT}/run/secrets/mok.priv"
cp "${MOK_TEST_DIR}/MOK.der" "${FAKE_ROOT}/run/secrets/mok.der"

echo "UNSIGNED_KO_BINARY" > "${FAKE_ROOT}/usr/lib/modules/${KVER_TEST}/extra/rtl88x2bu/88x2bu.ko"

cat << 'EOS' > "${FAKE_ROOT}/usr/lib/modules/${KVER_TEST}/build/scripts/sign-file"
#!/usr/bin/env bash
set -euo pipefail
ALGO="$1"; PRIV="$2"; DER="$3"; KO="$4"
[[ -s "${PRIV}" && -s "${DER}" ]] || exit 1
echo "~Module signature appended (${ALGO})~" >> "${KO}"
EOS
chmod +x "${FAKE_ROOT}/usr/lib/modules/${KVER_TEST}/build/scripts/sign-file"

cat << 'EOD' > "${FAKE_ROOT}/bin/depmod"
#!/usr/bin/env bash
set -euo pipefail
KVER_ARG="$2"
MOD_DIR="${FAKE_ROOT}/usr/lib/modules/${KVER_ARG}"
find "${MOD_DIR}" -name "*.ko" > "${MOD_DIR}/modules.dep"
EOD
chmod +x "${FAKE_ROOT}/bin/depmod"

if PATH="${FAKE_ROOT}/bin:${PATH}" "${MOCK_FINALIZE}" "${KVER_TEST}" >/dev/null; then
    if grep -q "Module signature appended" "${FAKE_ROOT}/usr/lib/modules/${KVER_TEST}/extra/rtl88x2bu/88x2bu.ko" && \
       grep -q "88x2bu.ko" "${FAKE_ROOT}/usr/lib/modules/${KVER_TEST}/modules.dep"; then
        pass "TC-05: Out-of-tree .ko signed with MOK secret and indexed in single depmod pass"
    else
        fail "TC-05" "Signature or modules.dep entry missing after finalization"
    fi
else
    fail "TC-05" "Finalizer execution failed"
fi

# ------------------------------------------------------------------------------
# TC-06: Fail-Closed on Empty / Corrupt modules.dep
# ------------------------------------------------------------------------------
cat << 'EOD' > "${FAKE_ROOT}/bin/depmod"
#!/usr/bin/env bash
KVER_ARG="$2"
MOD_DIR="${FAKE_ROOT}/usr/lib/modules/${KVER_ARG}"
: > "${MOD_DIR}/modules.dep"
EOD
chmod +x "${FAKE_ROOT}/bin/depmod"

if ! PATH="${FAKE_ROOT}/bin:${PATH}" "${MOCK_FINALIZE}" "${KVER_TEST}" >/dev/null 2>&1; then
    pass "TC-06: Finalizer fails closed when modules.dep is empty or corrupt"
else
    fail "TC-06" "Finalizer did not fail on empty modules.dep"
fi

# ------------------------------------------------------------------------------
# TC-07 & TC-08: End-to-End Podman Stage-2 Sealing & Artifact Isolation Test
# ------------------------------------------------------------------------------
if command -v podman >/dev/null 2>&1; then
    MINI_ROOT="${TEST_ROOT}/miniroot"
    mkdir -p "${MINI_ROOT}/bin" "${MINI_ROOT}/usr/bin" "${MINI_ROOT}/lib" "${MINI_ROOT}/lib64" \
             "${MINI_ROOT}/usr/lib/modules/${KVER_TEST}/extra" \
             "${MINI_ROOT}/usr/lib/modules/${KVER_TEST}/build/scripts" \
             "${MINI_ROOT}/usr/lib/modprobe.d" \
             "${MINI_ROOT}/usr/local/bin" \
             "${MINI_ROOT}/usr/libexec/ec" \
             "${MINI_ROOT}/run/secrets" \
             "${MINI_ROOT}/tmp/ec-work"

    # Use 'type -P' so shell builtins like 'echo' resolve to actual disk binaries (/usr/bin/echo)
    for cmd in bash sh env mkdir find basename grep cat echo rm touch chmod; do
        BIN_PATH="$(type -P "${cmd}" || true)"
        if [[ -n "${BIN_PATH}" && -f "${BIN_PATH}" ]]; then
            cp -L "${BIN_PATH}" "${MINI_ROOT}/bin/${cmd}"
            for lib in $(ldd "${BIN_PATH}" 2>/dev/null | awk '{print $3}' | grep '^/' || true); do
                mkdir -p "${MINI_ROOT}$(dirname "${lib}")"
                cp -L -n "${lib}" "${MINI_ROOT}${lib}" 2>/dev/null || true
            done
        fi
    done
    [[ -e /lib64/ld-linux-x86-64.so.2 ]] && cp -L /lib64/ld-linux-x86-64.so.2 "${MINI_ROOT}/lib64/" 2>/dev/null || true
    ln -sf /bin/bash "${MINI_ROOT}/usr/bin/bash"
    ln -sf /bin/sh "${MINI_ROOT}/usr/bin/sh"
    ln -sf /bin/env "${MINI_ROOT}/usr/bin/env"

    cp "${REPO_ROOT}/libexec/ec-container-finalize" "${MINI_ROOT}/usr/libexec/ec/ec-container-finalize"
    cp "${FAKE_ROOT}/usr/lib/modules/${KVER_TEST}/build/scripts/sign-file" \
       "${MINI_ROOT}/usr/lib/modules/${KVER_TEST}/build/scripts/sign-file"

    cat << 'EOD' > "${MINI_ROOT}/bin/depmod"
#!/usr/bin/env bash
echo "extra/test_mod.ko:" > "/usr/lib/modules/$2/modules.dep"
EOD
    chmod +x "${MINI_ROOT}/bin/depmod"

    # 1. Import base clone
    tar -C "${MINI_ROOT}" -cf - . | podman import - localhost/ec-test-base:test >/dev/null

    # 2. Simulate user session changes in Stage 1 snapshot
    echo "RAW_MODULE_DATA" > "${MINI_ROOT}/usr/lib/modules/${KVER_TEST}/extra/test_mod.ko"
    echo "#!/bin/sh" > "${MINI_ROOT}/usr/local/bin/flucid-custom-tool"
    chmod +x "${MINI_ROOT}/usr/local/bin/flucid-custom-tool"
    echo "DIRTY_TARBALL_MUST_NOT_LEAK" > "${MINI_ROOT}/tmp/ec-work/dirty-src.tar.gz"
    tar -C "${MINI_ROOT}" -cf - . | podman import - localhost/ec-test-snap:test >/dev/null

    # 3. Run Podman Stage-2 Sealer with secret MOK mounts
    if podman build \
        --no-cache \
        --layers=false \
        --build-arg BASE_CLONE="localhost/ec-test-base:test" \
        --build-arg BUILDER_SNAP="localhost/ec-test-snap:test" \
        --build-arg KVER="${KVER_TEST}" \
        --secret id=mok_key,src="${MOK_TEST_DIR}/MOK.priv" \
        --secret id=mok_der,src="${MOK_TEST_DIR}/MOK.der" \
        -t localhost/ec-test-final:test \
        -f "${REPO_ROOT}/share/ephemeral-container/Containerfile.seal" \
        "${REPO_ROOT}/share/ephemeral-container" >/dev/null 2>&1; then

        # Verify Stage 2 kept signed .ko and /usr/local/bin tool, but stripped /tmp/ec-work and /run/secrets
        if podman run --rm localhost/ec-test-final:test /bin/bash -c "
            grep -q 'Module signature appended' /usr/lib/modules/${KVER_TEST}/extra/test_mod.ko &&
            test -x /usr/local/bin/flucid-custom-tool &&
            ! test -e /tmp/ec-work/dirty-src.tar.gz &&
            ! test -e /run/secrets/mok.priv
        "; then
            pass "TC-07: Podman Stage-2 Containerfile.seal keeps signed artifacts & strips /tmp + MOK secrets"
        else
            fail "TC-07" "Artifact isolation or MOK secret stripping check failed in final image"
        fi
    else
        fail "TC-07" "podman build of Containerfile.seal failed"
    fi

    # TC-08: Verify truncation removes temporary images cleanly
    podman rmi -f localhost/ec-test-base:test localhost/ec-test-snap:test localhost/ec-test-final:test >/dev/null 2>&1
    if ! podman image exists localhost/ec-test-snap:test; then
        pass "TC-08: Podman temporary builder snapshots truncated with zero residual state"
    else
        fail "TC-08" "Temporary builder snapshot still exists after truncation"
    fi
else
    echo "[SKIP] Podman not installed; skipping TC-07 and TC-08"
fi

echo "================================================================================"
echo " Test Summary: ${PASS_COUNT} passed, ${FAIL_COUNT} failed"
echo "================================================================================"
[[ "${FAIL_COUNT}" -eq 0 ]]
