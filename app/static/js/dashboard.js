/* ==========================================================================
   관리자 대시보드 프런트엔드
   - CSP(script-src 'self' + cdn.jsdelivr.net)를 지키기 위해 인라인 스크립트를
     쓰지 않고, 데이터는 /api/admin/* 엔드포인트에서 fetch 한다.
   - 인증은 세션 쿠키로 처리되므로 별도 토큰이 필요 없다.
   ========================================================================== */
(function () {
  "use strict";

  /* ------------------------------------------------------- 공통 유틸 */

  const REFRESH_MS = 15000; // KPI/로그 갱신 주기
  let timers = [];

  function $(sel) { return document.querySelector(sel); }

  async function getJSON(url) {
    const res = await fetch(url, {
      headers: { "Accept": "application/json" },
      credentials: "same-origin",
    });
    if (!res.ok) {
      throw new Error("HTTP " + res.status);
    }
    return res.json();
  }

  function showChartError(canvas, message) {
    const box = canvas.parentElement;
    if (!box) return;
    box.innerHTML =
      '<p class="chart-error">' + message + "</p>";
  }

  function formatNumber(n) {
    return (n === null || n === undefined) ? "0" : Number(n).toLocaleString("ko-KR");
  }

  /* Chart.js 공통 테마 (다크 배경에 맞춤) */
  function applyTheme() {
    if (typeof Chart === "undefined") return;
    Chart.defaults.color = "#97a3b6";
    Chart.defaults.font.family =
      '-apple-system, BlinkMacSystemFont, "Segoe UI", "Malgun Gothic", sans-serif';
    Chart.defaults.font.size = 11;
    Chart.defaults.borderColor = "#2a3444";
    Chart.defaults.plugins.legend.labels.boxWidth = 12;
    Chart.defaults.plugins.legend.labels.usePointStyle = true;
    Chart.defaults.maintainAspectRatio = false;
  }

  /* ------------------------------------------------------- 트래픽 추이 차트 */

  async function initTrafficChart() {
    const canvas = document.getElementById("traffic-chart");
    if (!canvas || typeof Chart === "undefined") return;

    const hours = canvas.dataset.hours || "24";

    let data;
    try {
      data = await getJSON("/api/admin/timeline?hours=" + encodeURIComponent(hours));
    } catch (err) {
      showChartError(canvas, "트래픽 데이터를 불러올 수 없습니다. (" + err.message + ")");
      return;
    }

    if (!data.labels || data.labels.length === 0) {
      showChartError(canvas, "선택한 기간에 수집된 접속 기록이 없습니다.");
      return;
    }

    // 시간 라벨을 짧게 (예: "2026-09-03 14:00" → "09-03 14시")
    const labels = data.labels.map(function (s) {
      const m = /^\d{4}-(\d{2})-(\d{2})(?: (\d{2}):00)?$/.exec(s);
      if (!m) return s;
      return m[3] ? m[1] + "-" + m[2] + " " + m[3] + "시" : m[1] + "-" + m[2];
    });

    new Chart(canvas.getContext("2d"), {
      type: "line",
      data: {
        labels: labels,
        datasets: [
          {
            label: "전체 요청",
            data: data.total,
            borderColor: "#4f8cff",
            backgroundColor: "rgba(79,140,255,.16)",
            fill: true,
            tension: 0.32,
            borderWidth: 2,
            pointRadius: 0,
            pointHoverRadius: 4,
          },
          {
            label: "오류 응답 (4xx·5xx)",
            data: data.errors,
            borderColor: "#f0a63c",
            backgroundColor: "transparent",
            tension: 0.32,
            borderWidth: 1.6,
            pointRadius: 0,
            pointHoverRadius: 4,
          },
          {
            label: "위협 탐지",
            data: data.threats,
            borderColor: "#ef4d5a",
            backgroundColor: "rgba(239,77,90,.14)",
            fill: true,
            tension: 0.32,
            borderWidth: 1.8,
            pointRadius: 0,
            pointHoverRadius: 4,
          },
        ],
      },
      options: {
        responsive: true,
        interaction: { mode: "index", intersect: false },
        plugins: {
          legend: { position: "top", align: "end" },
          tooltip: {
            backgroundColor: "#1a202c",
            borderColor: "#2a3444",
            borderWidth: 1,
            padding: 10,
          },
        },
        scales: {
          x: { grid: { display: false }, ticks: { maxRotation: 0, autoSkipPadding: 14 } },
          y: {
            beginAtZero: true,
            grid: { color: "rgba(42,52,68,.65)" },
            ticks: { precision: 0 },
          },
        },
      },
    });
  }

  /* ------------------------------------------------------- 상태코드 분포 차트 */

  async function initStatusChart() {
    const canvas = document.getElementById("status-chart");
    if (!canvas || typeof Chart === "undefined") return;

    const hours = canvas.dataset.hours || "24";

    let data;
    try {
      data = await getJSON("/api/admin/status-dist?hours=" + encodeURIComponent(hours));
    } catch (err) {
      showChartError(canvas, "상태 코드 데이터를 불러올 수 없습니다.");
      return;
    }

    if (!data.labels || data.labels.length === 0) {
      showChartError(canvas, "표시할 응답 기록이 없습니다.");
      return;
    }

    const palette = {
      "1xx": "#6b7789",
      "2xx": "#2fbf71",
      "3xx": "#38bdf8",
      "4xx": "#f0a63c",
      "5xx": "#ef4d5a",
    };
    const colors = data.labels.map(function (l) { return palette[l] || "#6b7789"; });

    new Chart(canvas.getContext("2d"), {
      type: "doughnut",
      data: {
        labels: data.labels,
        datasets: [{
          data: data.values,
          backgroundColor: colors,
          borderColor: "#1a202c",
          borderWidth: 2,
          hoverOffset: 6,
        }],
      },
      options: {
        responsive: true,
        cutout: "58%",
        plugins: {
          legend: { position: "bottom" },
          tooltip: {
            backgroundColor: "#1a202c",
            borderColor: "#2a3444",
            borderWidth: 1,
            padding: 10,
            callbacks: {
              label: function (ctx) {
                const total = ctx.dataset.data.reduce(function (a, b) { return a + b; }, 0);
                const pct = total ? ((ctx.parsed / total) * 100).toFixed(1) : "0.0";
                return " " + ctx.label + ": " + formatNumber(ctx.parsed) + "건 (" + pct + "%)";
              },
            },
          },
        },
      },
    });
  }

  /* ------------------------------------------------------- KPI 실시간 갱신 */

  const KPI_MAP = {
    "kpi-total":   "total_requests",
    "kpi-ips":     "unique_ips",
    "kpi-threats": "threat_requests",
    "kpi-errors":  "error_requests",
  };

  async function refreshKpi() {
    const anchor = document.getElementById("kpi-total");
    if (!anchor) return;

    // 대시보드의 기간 선택값과 동일한 기준으로 조회한다
    const select = document.getElementById("hours-select");
    const hours = select ? select.value : "24";

    let data;
    try {
      data = await getJSON("/api/admin/live?hours=" + encodeURIComponent(hours));
    } catch (err) {
      // 세션이 만료되었거나 서버가 재시작(배포)된 상황.
      // 화면을 깨뜨리지 않고 폴링만 중단한다.
      stopTimers();
      return;
    }

    Object.keys(KPI_MAP).forEach(function (id) {
      const el = document.getElementById(id);
      if (!el) return;
      const next = formatNumber(data[KPI_MAP[id]]);
      if (el.textContent !== next) {
        el.textContent = next;
      }
    });
  }

  function stopTimers() {
    timers.forEach(clearInterval);
    timers = [];
  }

  /* ------------------------------------------------------- 초기화 */

  function init() {
    applyTheme();
    initTrafficChart();
    initStatusChart();

    if (document.getElementById("kpi-total")) {
      timers.push(setInterval(refreshKpi, REFRESH_MS));
    }

    // 탭이 백그라운드일 때는 폴링을 멈춰 불필요한 요청/로그를 만들지 않는다.
    document.addEventListener("visibilitychange", function () {
      if (document.hidden) {
        stopTimers();
      } else if (timers.length === 0 && document.getElementById("kpi-total")) {
        refreshKpi();
        timers.push(setInterval(refreshKpi, REFRESH_MS));
      }
    });
  }

  if (document.readyState === "loading") {
    document.addEventListener("DOMContentLoaded", init);
  } else {
    init();
  }
})();
