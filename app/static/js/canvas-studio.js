/*
 * Canvas AI Studio — Fabric.js 캔버스 편집 + 서버 프록시(/studio/generate) 호출.
 * CSP(script-src 'self' ...) 때문에 인라인 스크립트를 쓸 수 없어 외부 파일로 분리한다.
 */
(function () {
  "use strict";

  const CANVAS_W = 900;
  const CANVAS_H = 600;
  const MAX_HISTORY = 50;

  const shell = document.getElementById("studio-shell");
  if (!shell || typeof fabric === "undefined") return;

  const generateUrl = shell.dataset.generateUrl;
  const csrfToken = shell.dataset.csrf;

  const canvas = new fabric.Canvas("main-canvas", {
    width: CANVAS_W,
    height: CANVAS_H,
    backgroundColor: "#FFFFFF",
    selection: true,
    preserveObjectStacking: true,
  });

  let currentTool = "select";
  let isDrawing = false;
  let startX = 0, startY = 0, activeShape = null;
  let history = [];
  let historyIdx = -1;
  let suppressHistory = false;

  const $ = (id) => document.getElementById(id);
  const statusBar = $("status-bar");
  const objectCount = $("object-count");

  function setStatus(text, kind) {
    statusBar.textContent = text;
    statusBar.className = "studio-status-bar" + (kind ? " is-" + kind : "");
  }

  function updateObjectCount() {
    objectCount.textContent = canvas.getObjects().length + "개 오브젝트";
  }

  function saveState() {
    if (suppressHistory) return;
    const json = JSON.stringify(canvas.toJSON());
    if (historyIdx < history.length - 1) history = history.slice(0, historyIdx + 1);
    history.push(json);
    if (history.length > MAX_HISTORY) history.shift();
    historyIdx = history.length - 1;
    updateObjectCount();
  }

  function loadState(json) {
    suppressHistory = true;
    canvas.loadFromJSON(json, () => {
      canvas.renderAll();
      suppressHistory = false;
      updateObjectCount();
    });
  }

  function undo() {
    if (historyIdx <= 0) return;
    loadState(history[--historyIdx]);
  }

  function redo() {
    if (historyIdx >= history.length - 1) return;
    loadState(history[++historyIdx]);
  }

  function setTool(tool) {
    currentTool = tool;
    canvas.isDrawingMode = tool === "draw";
    canvas.selection = tool === "select";
    canvas.forEachObject((o) => { o.selectable = tool === "select"; });
    document.querySelectorAll(".tool-btn[data-tool]").forEach((btn) => {
      btn.classList.toggle("is-active", btn.dataset.tool === tool);
    });
  }

  function deleteSelected() {
    const objs = canvas.getActiveObjects();
    if (!objs.length) return;
    objs.forEach((o) => canvas.remove(o));
    canvas.discardActiveObject();
    canvas.renderAll();
    saveState();
  }

  function currentProps() {
    return {
      fill: $("fill-color").value,
      stroke: $("stroke-color").value,
      strokeWidth: +$("stroke-width").value,
      opacity: +$("opacity-slider").value / 100,
    };
  }

  // ------------------------------------------------------------ 도형 그리기
  canvas.on("mouse:down", (opt) => {
    if (["select", "draw"].includes(currentTool)) return;
    const p = canvas.getPointer(opt.e);
    startX = p.x; startY = p.y; isDrawing = true;
    const props = currentProps();

    if (currentTool === "text") {
      const t = new fabric.IText("텍스트 입력", {
        left: startX, top: startY,
        fontSize: +$("font-size").value, fill: props.fill,
      });
      canvas.add(t);
      canvas.setActiveObject(t);
      t.enterEditing();
      isDrawing = false;
      saveState();
      setTool("select");
      return;
    }

    const shapeMap = {
      rect: () => new fabric.Rect({ left: startX, top: startY, width: 0, height: 0, ...props }),
      circle: () => new fabric.Ellipse({ left: startX, top: startY, rx: 0, ry: 0, ...props }),
      triangle: () => new fabric.Triangle({ left: startX, top: startY, width: 0, height: 0, ...props }),
      line: () => new fabric.Line([startX, startY, startX, startY], { stroke: props.fill, strokeWidth: props.strokeWidth || 1 }),
    };
    activeShape = shapeMap[currentTool] ? shapeMap[currentTool]() : null;
    if (activeShape) canvas.add(activeShape);
  });

  canvas.on("mouse:move", (opt) => {
    if (!isDrawing || !activeShape) return;
    const p = canvas.getPointer(opt.e);
    const w = Math.abs(p.x - startX), h = Math.abs(p.y - startY);
    const l = Math.min(p.x, startX), t = Math.min(p.y, startY);

    if (["rect", "triangle"].includes(currentTool)) {
      activeShape.set({ left: l, top: t, width: w, height: h });
    } else if (currentTool === "circle") {
      activeShape.set({ left: l, top: t, rx: w / 2, ry: h / 2 });
    } else if (currentTool === "line") {
      activeShape.set({ x2: p.x, y2: p.y });
    }
    canvas.renderAll();
  });

  canvas.on("mouse:up", () => {
    if (!isDrawing) return;
    isDrawing = false;
    activeShape = null;
    saveState();
    setTool("select");
  });

  canvas.on("path:created", saveState);
  canvas.on("object:modified", saveState);

  // ------------------------------------------------------------ 이미지 업로드
  function handleImageUpload(e) {
    const file = e.target.files[0];
    if (!file) return;
    const reader = new FileReader();
    reader.onload = (ev) => {
      fabric.Image.fromURL(ev.target.result, (img) => {
        img.scaleToWidth(Math.min(300, CANVAS_W / 2));
        img.set({ left: 50, top: 50 });
        canvas.add(img);
        canvas.setActiveObject(img);
        canvas.renderAll();
        saveState();
      });
    };
    reader.readAsDataURL(file);
    e.target.value = "";
  }

  // ------------------------------------------------------------ 툴바 이벤트
  document.querySelectorAll(".tool-btn[data-tool]").forEach((btn) => {
    btn.addEventListener("click", () => setTool(btn.dataset.tool));
  });

  document.querySelectorAll(".tool-btn[data-action]").forEach((btn) => {
    btn.addEventListener("click", () => {
      const action = btn.dataset.action;
      if (action === "image") $("image-input").click();
      if (action === "undo") undo();
      if (action === "redo") redo();
      if (action === "delete") deleteSelected();
      if (action === "clear") {
        if (confirm("캔버스를 전부 지울까요?")) {
          canvas.clear();
          canvas.backgroundColor = "#FFFFFF";
          canvas.renderAll();
          saveState();
        }
      }
    });
  });

  $("image-input").addEventListener("change", handleImageUpload);

  document.addEventListener("keydown", (e) => {
    if (["INPUT", "TEXTAREA"].includes(e.target.tagName)) return;
    if (document.activeElement && document.activeElement.isContentEditable) return;

    const map = { v: "select", r: "rect", c: "circle", l: "line", t: "text", p: "draw" };
    const key = e.key.toLowerCase();
    if (map[key]) setTool(map[key]);
    if (e.key === "Delete" || e.key === "Backspace") { e.preventDefault(); deleteSelected(); }
    if ((e.ctrlKey || e.metaKey) && key === "z") { e.preventDefault(); undo(); }
    if ((e.ctrlKey || e.metaKey) && key === "y") { e.preventDefault(); redo(); }
  });

  // ------------------------------------------------------------ AI 전송
  async function sendToAI() {
    if (!generateUrl) return;
    const prompt = $("api-prompt").value.trim();
    const sendBtn = $("send-btn");

    sendBtn.disabled = true;
    setStatus("AI에게 전송 중...", "busy");

    try {
      const imageData = canvas.toDataURL({ format: "png", multiplier: 1 });
      const canvasJSON = canvas.toJSON();

      const res = await fetch(generateUrl, {
        method: "POST",
        headers: {
          "Content-Type": "application/json",
          "X-CSRF-Token": csrfToken,
        },
        body: JSON.stringify({ image: imageData, canvas: canvasJSON, prompt }),
      });

      const data = await res.json().catch(() => ({}));
      if (!res.ok) {
        throw new Error(data.error || `HTTP ${res.status}`);
      }

      $("md-output").textContent = data.markdown || "";
      setStatus("완료됨", "ok");
    } catch (err) {
      setStatus("실패: " + err.message, "error");
    } finally {
      sendBtn.disabled = false;
    }
  }

  $("send-btn").addEventListener("click", sendToAI);

  // ------------------------------------------------------------ 마크다운 출력
  $("copy-btn").addEventListener("click", async () => {
    const text = $("md-output").textContent;
    if (!text) return;
    try {
      await navigator.clipboard.writeText(text);
      setStatus("클립보드에 복사됨", "ok");
    } catch {
      setStatus("클립보드 복사 실패 (브라우저 권한 확인)", "error");
    }
  });

  $("download-btn").addEventListener("click", () => {
    const text = $("md-output").textContent;
    if (!text) return;
    const blob = new Blob([text], { type: "text/markdown;charset=utf-8" });
    const url = URL.createObjectURL(blob);
    const a = Object.assign(document.createElement("a"), {
      href: url,
      download: `layout-${new Date().toISOString().slice(0, 10)}.md`,
    });
    document.body.appendChild(a);
    a.click();
    document.body.removeChild(a);
    URL.revokeObjectURL(url);
  });

  // ------------------------------------------------------------ 초기 상태
  saveState();
  setTool("select");
})();
