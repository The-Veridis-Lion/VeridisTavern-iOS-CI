import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import fs from 'node:fs';
import net from 'node:net';
import { setTimeout as delay } from 'node:timers/promises';
import { pathToFileURL } from 'node:url';

const variants = ['M2', 'After', 'After', 'M2'];
const warmups = 3;
const conversions = 6;
const hash = value => createHash('sha256').update(value).digest('hex');

// Standalone recipe. This benchmark accepts no text, settings, or replay files.
export function publicMarkdown() {
    const paragraphs = 358;
    const units = 180_016 - 2 * (paragraphs - 1);
    const sentence = 'An amber kite crossed the quiet square while two clocks marked the hour. 风吹过广场，风筝越过钟楼。 ';
    return Array.from({ length: paragraphs }, (_, index) => {
        const size = Math.floor(units / paragraphs) + Number(index < units % paragraphs);
        const lead = `Paragraph ${index + 1}. The drawing shows a bridge.`;
        const quote = index === paragraphs - 1 ? ' A sign said <q>Wind from the west</q>.' : '';
        const remaining = size - lead.length - quote.length;
        return lead + quote + (' ' + sentence.repeat(Math.ceil(remaining / sentence.length))).slice(0, remaining);
    }).join('\n\n');
}

export function measureConversions(converter, showdown, input, warmupCount, sampleCount, now) {
    const subParser = showdown.subParser('hashHTMLBlocks');
    let measurement;
    // Showdown's event observers cannot be removed. These become inert after the
    // block, and the caller reinstalls the app before each subsequent block.
    converter.listen('hashHTMLBlocks.before', () => { if (measurement) measurement.beforeEvents++; });
    converter.listen('hashHTMLBlocks.after', () => { if (measurement) measurement.afterEvents++; });
    showdown.subParser('hashHTMLBlocks', function (...args) {
        const start = now();
        try {
            return Reflect.apply(subParser, this, args);
        } finally {
            measurement.blockCalls++;
            measurement.blocksMs += now() - start;
        }
    });
    try {
        let html;
        const samples = [];
        for (let run = 0; run < warmupCount + sampleCount; run++) {
            measurement = { blocksMs: 0, blockCalls: 0, beforeEvents: 0, afterEvents: 0 };
            const start = now();
            const result = converter.makeHtml(input);
            const totalMs = now() - start;
            html ??= result;
            if (result !== html || measurement.blockCalls !== 2 || measurement.beforeEvents !== 2 ||
                measurement.afterEvents !== 2) throw Error('unexpected-markdown-output-or-events');
            if (run >= warmupCount) samples.push({ totalMs, ...measurement });
        }
        return { html, samples };
    } finally {
        measurement = undefined;
        showdown.subParser('hashHTMLBlocks', subParser);
    }
}

// Fresh upstream settings pause in the built-in persona dialog. Use its actual
// Save action and keep the stock input, without seeding or rewriting settings.
export function pageReadiness(acceptOnboarding) {
    const stage = globalThis.__TAURITAVERN_STARTUP_STAGE__;
    const documentReady = ['loading', 'interactive', 'complete'].includes(document.readyState) ? document.readyState : 'other';
    const visible = document.visibilityState === 'visible';
    const nativeIos = globalThis.__TAURITAVERN_HOST__?.platform === 'ios';
    const invokeReady = typeof (globalThis.__TAURI__?.core ?? globalThis.__TAURI_INTERNALS__)?.invoke === 'function';
    const assetsReady = globalThis.__TAURI_RUNNING__ === true && typeof globalThis.SillyTavern?.getContext === 'function';
    const appFull = stage === 'full' && !document.querySelector('#tt-startup-status-overlay');
    const startupFailed = Boolean(document.querySelector('#tt-startup-failure'));
    const dialog = document.querySelector('dialog.popup[open]');
    const onboarding = Boolean(dialog?.querySelector('.popup-content .onboarding #onboarding_ui_language_select') &&
        dialog.querySelector('textarea.popup-input'));
    let acceptedOnboarding = false;
    if (acceptOnboarding && onboarding && stage === 'full' && !appFull && !startupFailed &&
        documentReady === 'complete' && visible && nativeIos && invokeReady && assetsReady) {
        const button = dialog.querySelector('button.popup-button-ok[data-result="1"]:not(:disabled)');
        if (button?.getClientRects().length) {
            button.click();
            acceptedOnboarding = true;
        }
    }
    return { documentReady, visible, nativeIos, invokeReady, assetsReady, appFull, startupFailed,
        stage: ['shell', 'core', 'full'].includes(stage) ? stage : 'unknown', onboarding, acceptedOnboarding };
}

// Runs inside the existing main WKWebView on the booted Simulator.
async function pageBenchmark(variant, makeInput, measure, warmupCount, sampleCount) {
    const core = globalThis.__TAURI__?.core ?? globalThis.__TAURI_INTERNALS__;
    if (globalThis.__TAURITAVERN_HOST__?.platform !== 'ios' || document.visibilityState !== 'visible' ||
        typeof core?.invoke !== 'function') throw Error('native-ios-webview-unavailable');
    const native = await core.invoke('get_client_version');
    const expected = variant === 'M2' ? /^m2-[0-9a-f]{9}$/ : /^after-[0-9a-f]{9}$/;
    if (!expected.test(native?.gitRevision)) throw Error('unexpected-native-build');
    const asset = path => new URL(path, location.href).href;
    const [app, lib] = await Promise.all([import(asset('/script.js')), import(asset('/lib.js'))])
        .catch(() => { throw Error('bundled-markdown-assets-unavailable'); });
    if (typeof app.converter?.makeHtml !== 'function') throw Error('converter-not-ready');
    const input = makeInput();
    const { html, samples } = measure(app.converter, lib.showdown, input, warmupCount, sampleCount, () => performance.now());
    const encoder = new TextEncoder();
    const inputBytes = encoder.encode(input);
    return {
        nativeIos: true, nativeVariantMatches: true, warmups: warmupCount, samples,
        inputUtf16: input.length, inputBytes: inputBytes.length, inputSha256: lib.sha256(inputBytes),
        outputSha256: lib.sha256(encoder.encode(html)),
        outputParagraphs: [...html.matchAll(/<p>/g)].length, outputQuotes: [...html.matchAll(/<q>/g)].length,
    };
}

// Pilot 0.8.1 exposes newline-delimited JSON-RPC over the fresh app's Unix socket.
function pilot(socketPath, method, params) {
    return new Promise((resolve, reject) => {
        const socket = net.createConnection(socketPath);
        let pending = '';
        const timer = setTimeout(() => finish(Error('pilot-timeout')), 12000);
        function finish(error, result) {
            clearTimeout(timer);
            socket.destroy();
            if (error) reject(error);
            else resolve(result);
        }
        socket.setEncoding('utf8');
        socket.once('connect', () => socket.write(JSON.stringify({ jsonrpc: '2.0', id: 1, method, params }) + '\n'));
        socket.once('error', () => finish(Error('pilot-connection-error')));
        socket.once('end', () => finish(Error('pilot-incomplete-reply')));
        socket.on('data', chunk => {
            pending += chunk;
            if (pending.length > 32768) return finish(Error('pilot-unexpected-reply-size'));
            const newline = pending.indexOf('\n');
            if (newline === -1) return;
            try {
                const data = JSON.parse(pending.slice(0, newline));
                if (data.jsonrpc !== '2.0' || data.id !== 1 || data.error) throw Error('pilot-unexpected-reply');
                finish(null, data.result);
            } catch {
                finish(Error('pilot-unexpected-reply'));
            }
        });
    });
}

async function runBlock(variant, stateFile) {
    const state = JSON.parse(fs.readFileSync(stateFile, 'utf8'));
    assert.ok(state.bundleId === 'com.tauritavern.client' &&
        /^\/tmp\/vtios\.[a-zA-Z0-9]+\/tauri-pilot-com\.tauritavern\.client\.sock$/.test(state.pilotSocket), 'simulator-state');
    const rpc = (method, params) => pilot(state.pilotSocket, method, params);
    const evalMain = script => rpc('eval', { window: 'main', script });
    const pong = await rpc('ping');
    assert.ok(pong?.status === 'ok' && pong.plugin_version === '0.8.1', 'pilot-version');
    const resolveBy = Date.now() + 90_000;
    let readiness;
    let onboardingAccepted = false;
    while (Date.now() < resolveBy) {
        const status = await evalMain(`(${pageReadiness.toString()})(${!onboardingAccepted})`).catch(() => null);
        if (status) readiness = status;
        if (status?.acceptedOnboarding === true) onboardingAccepted = true;
        if (status?.startupFailed || (status?.documentReady === 'complete' && status.visible &&
            status.nativeIos && status.invokeReady && status.assetsReady && status.appFull)) break;
        await delay(750);
    }
    if (!readiness?.appFull || readiness.startupFailed || readiness.documentReady !== 'complete' ||
        !readiness.visible || !readiness.nativeIos || !readiness.invokeReady || !readiness.assetsReady) {
        console.error('native-startup-phase', JSON.stringify({ ...readiness, onboardingAccepted }));
        throw Error(readiness?.startupFailed ? 'native-ios-startup-failed' : 'native-ios-app-not-ready');
    }
    // Pilot eval has a short RPC deadline. Launch once and poll only its small report.
    const started = await evalMain(`(() => {
        const job = globalThis.__vtPublicMarkdown = {done:false};
        Promise.resolve().then(() => (${pageBenchmark.toString()})(${JSON.stringify(variant)},
            ${publicMarkdown.toString()}, ${measureConversions.toString()}, ${warmups}, ${conversions})).then(
            result => {job.result=result;job.done=true;}, error => {
                const known = ['native-ios-webview-unavailable', 'unexpected-native-build', 'bundled-markdown-assets-unavailable',
                    'converter-not-ready', 'unexpected-markdown-output-or-events'];
                job.failed = known.includes(error?.message) ? error.message : 'native-markdown-benchmark-failed';
                job.done=true;
            });
        return true;
    })()`);
    assert.equal(started, true, 'markdown-job-not-started');
    const deadline = Date.now() + 45000;
    while (Date.now() < deadline) {
        await delay(400);
        const job = await evalMain('globalThis.__vtPublicMarkdown').catch(() => null);
        if (job?.done) {
            await evalMain('delete globalThis.__vtPublicMarkdown');
            if (job.failed) throw Error(job.failed);
            assert.ok(job.result, 'native-markdown-benchmark-failed');
            return validateBlock({ ...job.result, onboardingAccepted });
        }
    }
    throw Error('native-markdown-benchmark-timeout');
}

function validateBlock(input) {
    const text = publicMarkdown();
    assert.ok(input?.nativeIos === true && input.nativeVariantMatches === true && typeof input.onboardingAccepted === 'boolean' &&
        input.warmups === warmups &&
        input.inputUtf16 === text.length && input.inputBytes === Buffer.byteLength(text) &&
        input.inputSha256 === hash(text) && /^[0-9a-f]{64}$/.test(input.outputSha256) &&
        input.outputParagraphs === 358 && input.outputQuotes === 1 && input.samples.length === conversions, 'invalid-block');
    const samples = input.samples.map(({ totalMs, blocksMs, blockCalls, beforeEvents, afterEvents }) => {
        assert.ok(Number.isFinite(totalMs) && totalMs >= 0 && Number.isFinite(blocksMs) && blocksMs >= 0 &&
            blocksMs <= totalMs + 1 && blockCalls === 2 && beforeEvents === blockCalls && afterEvents === blockCalls, 'sample-timing-or-events');
        return { totalMs, blocksMs, blockCalls, beforeEvents, afterEvents };
    });
    const { nativeIos, nativeVariantMatches, inputUtf16, inputBytes, inputSha256, outputSha256, outputParagraphs, outputQuotes } = input;
    return { nativeIos, nativeVariantMatches, inputUtf16, inputBytes, inputSha256, outputSha256,
        outputParagraphs, outputQuotes, onboardingAccepted: input.onboardingAccepted, warmups, samples };
}

function summarize(blocks) {
    assert.equal(blocks.length, variants.length, 'wrong-number-of-blocks');
    const [first] = blocks;
    assert.ok(blocks.every(block => block.outputSha256 === first.outputSha256), 'native-variant-html-differs');
    const { inputUtf16, inputBytes, inputSha256, outputSha256, outputParagraphs, outputQuotes } = first;
    const both = {};
    for (const variant of ['M2', 'After']) {
        const matching = blocks.filter((_, index) => variants[index] === variant);
        const samples = matching.flatMap(block => block.samples);
        const mean = key => samples.reduce((sum, sample) => sum + sample[key], 0) / samples.length;
        const count = key => samples.reduce((sum, sample) => sum + sample[key], 0);
        both[variant] = { conversions: samples.length, warmups: matching.length * warmups, totalMeanMs: mean('totalMs'),
            blocksMeanMs: mean('blocksMs'), blockCalls: count('blockCalls'), beforeEvents: count('beforeEvents'),
            afterEvents: count('afterEvents'), stockOnboardingAccepted: matching.filter(block => block.onboardingAccepted).length,
            samples };
    }
    return { nativeIos: true, nativeVariantsVerified: true, sameOutput: true, order: variants,
        inputUtf16, inputBytes, inputSha256, outputSha256, outputParagraphs, outputQuotes, variants: both };
}

async function main() {
    const [command, ...args] = process.argv.slice(2);
    let report;
    if (command === 'block' && args.length === 2 && ['M2', 'After'].includes(args[0])) report = await runBlock(...args);
    else if (command === 'compare' && args.length === variants.length) {
        report = summarize(args.map(file => validateBlock(JSON.parse(fs.readFileSync(file, 'utf8')))));
    } else throw Error('usage: benchmark.mjs block <M2|After> <fresh-simulator.json> or compare <four block reports>');
    console.log(JSON.stringify(report, null, 2));
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
    main().catch(error => {
        const message = /^[a-z0-9 -]+$/.test(error.message) ? error.message : 'public-markdown-benchmark-error';
        console.error(message);
        process.exitCode = 1;
    });
}
