# shellcheck shell=bash
# Generate all fixtures successfully before accepting any noise-rejection result.
e2e_run_noise_suite() {
    local variant="$1" directory name
    mkdir -p .agents/e2e
    directory="$(mktemp -d .agents/e2e/noise.XXXXXX)"
    command -v ffmpeg >/dev/null || { echo 'FAIL: ffmpeg is required'; return 1; }
    ffmpeg -y -f lavfi -i 'anoisesrc=c=white:r=16000:a=0.5' -t 10 "$directory/white.wav" >/dev/null 2>&1 || return 1
    ffmpeg -y -f lavfi -i 'sine=f=440:r=16000:d=10' -filter:a 'volume=0.5' "$directory/tone.wav" >/dev/null 2>&1 || return 1
    case "$variant" in
        multitone)
            ffmpeg -y -f lavfi -i 'sine=f=261:r=16000:d=10' -f lavfi -i 'sine=f=330:r=16000:d=10' \
                -f lavfi -i 'sine=f=392:r=16000:d=10' -f lavfi -i 'sine=f=523:r=16000:d=10' \
                -filter_complex 'amix=inputs=4:duration=longest,volume=0.4' "$directory/$variant.wav" >/dev/null 2>&1 || return 1
            ;;
        typing)
            ffmpeg -y -f lavfi -i 'anoisesrc=c=brown:r=16000:a=0.5' -filter:a 'apulsator=mode=sine:hz=5' \
                -t 10 "$directory/$variant.wav" >/dev/null 2>&1 || return 1
            ;;
        *) echo 'FAIL: unknown noise scenario'; return 1 ;;
    esac
    ffmpeg -y -f lavfi -i 'anullsrc=r=16000:cl=mono' -t 10 "$directory/silence.wav" >/dev/null 2>&1 || return 1
    for name in white tone "$variant" silence; do
        [[ -s "$directory/$name.wav" ]] || { echo "FAIL: missing $name fixture"; return 1; }
    done
    for name in white tone "$variant" silence; do
        (
            e2e_prepare_scenario
            export SPEAKFLOW_E2E_TEST_NOISE_REJECTION=1
            export SPEAKFLOW_E2E_AUDIO_FILE_PATH="$directory/$name.wav"
            export SPEAKFLOW_E2E_RECORD_SECONDS=12
            export SPEAKFLOW_E2E_TIMEOUT_SECONDS=25
            export SPEAKFLOW_E2E_TEST_AUTO_END=false
            e2e_run_asserted_case "$name rejection" noChunks
        ) || return 1
    done
}
