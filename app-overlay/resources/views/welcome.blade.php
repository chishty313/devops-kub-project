<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8" />
    <meta name="viewport" content="width=device-width, initial-scale=1" />
    <title>Laravel Kubernetes Deployment Test</title>
    <link rel="preconnect" href="https://fonts.googleapis.com" />
    <link rel="preconnect" href="https://fonts.gstatic.com" crossorigin />
    <link
        href="https://fonts.googleapis.com/css2?family=Inter:wght@300;400;500;600;700&family=JetBrains+Mono:wght@400;500&display=swap"
        rel="stylesheet"
    />
    <style>
        * { box-sizing: border-box; margin: 0; padding: 0; }
        :root {
            --bg-1: #0b1020;
            --bg-2: #1a1247;
            --bg-3: #4c1d95;
            --accent: #22d3ee;
            --accent-2: #a78bfa;
            --ok: #34d399;
            --text: #f8fafc;
            --muted: #94a3b8;
            --card: rgba(255, 255, 255, 0.06);
            --border: rgba(255, 255, 255, 0.12);
            --mono: 'JetBrains Mono', ui-monospace, SFMono-Regular, Menlo, Monaco, monospace;
        }
        html, body {
            min-height: 100vh;
            font-family: 'Inter', system-ui, -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif;
            color: var(--text);
            background: radial-gradient(1200px 700px at 0% 0%, rgba(124, 58, 237, 0.35), transparent 60%),
                        radial-gradient(900px 600px at 100% 100%, rgba(34, 211, 238, 0.25), transparent 55%),
                        linear-gradient(135deg, var(--bg-1) 0%, var(--bg-2) 50%, var(--bg-3) 100%);
            background-attachment: fixed;
            -webkit-font-smoothing: antialiased;
        }
        body { padding: 4rem 1.5rem; display: flex; flex-direction: column; align-items: center; gap: 2rem; }
        .badge {
            display: inline-flex; align-items: center; gap: 0.5rem;
            padding: 0.4rem 0.9rem; border-radius: 999px;
            background: rgba(52, 211, 153, 0.12); color: var(--ok);
            border: 1px solid rgba(52, 211, 153, 0.35);
            font-size: 0.85rem; font-weight: 500; letter-spacing: 0.02em;
        }
        .badge .dot {
            width: 8px; height: 8px; border-radius: 999px; background: var(--ok);
            box-shadow: 0 0 0 0 rgba(52, 211, 153, 0.7);
            animation: pulse 1.6s ease-out infinite;
        }
        @keyframes pulse {
            0%   { box-shadow: 0 0 0 0   rgba(52, 211, 153, 0.6); }
            70%  { box-shadow: 0 0 0 14px rgba(52, 211, 153, 0); }
            100% { box-shadow: 0 0 0 0   rgba(52, 211, 153, 0); }
        }
        h1 {
            font-size: clamp(1.8rem, 4.4vw, 3.2rem);
            font-weight: 700; line-height: 1.15; letter-spacing: -0.02em;
            text-align: center; max-width: 920px;
            background: linear-gradient(120deg, #ffffff 0%, var(--accent) 50%, var(--accent-2) 100%);
            -webkit-background-clip: text; background-clip: text;
            color: transparent;
        }
        .subtitle {
            color: var(--muted); font-size: 1.05rem; text-align: center;
            max-width: 640px; line-height: 1.6;
        }
        .card {
            width: 100%; max-width: 920px;
            background: var(--card);
            backdrop-filter: blur(18px); -webkit-backdrop-filter: blur(18px);
            border: 1px solid var(--border);
            border-radius: 18px; padding: 2rem;
            box-shadow: 0 30px 80px -20px rgba(0, 0, 0, 0.5);
        }
        .grid {
            display: grid; gap: 1rem;
            grid-template-columns: repeat(auto-fit, minmax(220px, 1fr));
        }
        .stat {
            background: rgba(255, 255, 255, 0.03);
            border: 1px solid var(--border);
            border-radius: 12px; padding: 1.1rem 1.2rem;
        }
        .stat dt {
            font-size: 0.78rem; text-transform: uppercase; letter-spacing: 0.08em;
            color: var(--muted); margin-bottom: 0.45rem;
        }
        .stat dd { font-family: var(--mono); font-size: 1rem; word-break: break-all; }
        .stat dd.accent { color: var(--accent); font-weight: 500; }
        .stat dd.accent-2 { color: var(--accent-2); }
        .endpoints {
            display: grid; gap: 0.6rem;
            grid-template-columns: 1fr; margin-top: 1.4rem;
        }
        .endpoint {
            display: flex; align-items: center; justify-content: space-between;
            padding: 0.75rem 1rem; border-radius: 10px;
            background: rgba(255, 255, 255, 0.04);
            border: 1px solid var(--border);
            font-family: var(--mono); font-size: 0.92rem;
        }
        .endpoint .path { color: var(--accent); }
        .endpoint .desc { color: var(--muted); font-family: 'Inter', sans-serif; font-size: 0.85rem; }
        footer {
            margin-top: 1.5rem; color: var(--muted); font-size: 0.85rem;
            text-align: center; line-height: 1.7;
        }
        footer code {
            font-family: var(--mono); padding: 2px 6px;
            background: rgba(255, 255, 255, 0.06); border-radius: 4px; color: var(--text);
        }
        a { color: var(--accent); text-decoration: none; }
        a:hover { text-decoration: underline; }
        .stack {
            display: flex; flex-wrap: wrap; gap: 0.5rem; justify-content: center;
            margin-top: 0.5rem;
        }
        .chip {
            padding: 0.3rem 0.7rem; border-radius: 999px;
            background: rgba(255, 255, 255, 0.06); border: 1px solid var(--border);
            font-size: 0.78rem; color: var(--muted); font-family: var(--mono);
        }
    </style>
</head>
<body>
    <span class="badge"><span class="dot"></span> 200 OK · serving live from Kubernetes</span>

    <h1>Laravel Kubernetes Deployment Test</h1>
    <p class="subtitle">
        This page is rendered by a Laravel {{ $laravel }} pod, running inside a multi-node
        kubeadm cluster, packaged with a custom Helm chart, and reached through ingress-nginx
        behind the host's nginx reverse proxy.
    </p>

    <div class="stack">
        <span class="chip">Laravel {{ $laravel }}</span>
        <span class="chip">PHP {{ $phpVersion }}</span>
        <span class="chip">nginx + php-fpm</span>
        <span class="chip">kubeadm · 3 CP / 2 worker</span>
        <span class="chip">Calico CNI</span>
        <span class="chip">ingress-nginx</span>
        <span class="chip">cert-manager</span>
        <span class="chip">ArgoCD</span>
    </div>

    <section class="card" aria-labelledby="runtime-heading">
        <h2 id="runtime-heading" style="font-size:1.1rem;font-weight:600;margin-bottom:1rem;letter-spacing:-0.01em;">
            Runtime details
        </h2>
        <dl class="grid">
            <div class="stat">
                <dt>Pod (hostname)</dt>
                <dd class="accent">{{ $pod }}</dd>
            </div>
            <div class="stat">
                <dt>App env</dt>
                <dd class="accent-2">{{ $appEnv }}</dd>
            </div>
            <div class="stat">
                <dt>App name</dt>
                <dd>{{ $appName }}</dd>
            </div>
            <div class="stat">
                <dt>Server time (UTC)</dt>
                <dd>{{ $now }}</dd>
            </div>
        </dl>

        <div class="endpoints">
            <div class="endpoint">
                <span><span class="path">GET&nbsp;/health</span></span>
                <span class="desc">JSON · liveness &amp; readiness probe target</span>
            </div>
            <div class="endpoint">
                <span><span class="path">GET&nbsp;/info</span></span>
                <span class="desc">JSON · pod &amp; runtime introspection</span>
            </div>
        </div>
    </section>

    <footer>
        Reload the page; the <code>Pod</code> value should rotate as ingress-nginx
        load-balances across replicas.<br />
        Repo: <a href="https://github.com/chishty313/devops-kub-project">github.com/chishty313/devops-kub-project</a>
        · Image: <code>docker.io/src313/laravel-k8s</code>
    </footer>
</body>
</html>
