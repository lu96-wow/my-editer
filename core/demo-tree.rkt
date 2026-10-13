#lang racket
(require "editor.rkt" "view/base/screen.rkt")

;; ================= 1. 建 buffer / view =================

;; 文件树：一个普通 buffer，内容由宿主（树模型）生成
(define (tree-text) (string-join '("src/" "  main.rkt" "  util.rkt" "README.md") "\n"))
(define tree-b (make-buffer (tree-text) "*tree*"))
(define tree-v (buffer-add-view! tree-b 24 10))          ; 面板：默认无行号

;; 主编辑区：打开的文件
(define doc-b (make-buffer "hello\nworld" "main.rkt"))
(define doc-v (buffer-add-view! doc-b 56 10 #:line-numbers? #t))

;; ================= 2. 宿主布局：算几何，把尺寸落进 view =================
;; 树在左 (x=0)；编辑区在右 (x=24)。布局变化时调用一次。
(view-resize! tree-v 24 10)
(view-resize! doc-v 56 10)

;; ================= 3. 渲染（两步） =================
;; 步 1：每个可见区域 → 一条 display-entry（view + 贴在屏幕哪）
(define (entries)
  (list (display-entry tree-v 0  0 0)     ; (view x y deep)
        (display-entry doc-v  24 0 0)))

;; 步 2：合成成一个完整帧。focus = 焦点 view（只有它画光标/选区）
(define frame (render-display (entries) doc-v 80 10))
(displayln "======== 第一帧 ========")
(displayln (screen->string frame))

;; ================= 4. 交互：编辑主编辑区 =================
(set-view-selections! doc-v (selections-one (caret (point 1 0))))   ; 光标到第二行行首
(buffer-edit! doc-b doc-v (op-type ">> "))                          ; 打字

;; 第二帧：旧帧 + 新状态 → 增量
(define-values (frame2 rends sels) (render-display-patch (entries) doc-v 80 10 frame))
(displayln "======== 第二帧（增量） ========")
(displayln (screen->string frame2))
(displayln (list "render 差分片" (length rends) "selection 差分片" (length sels)))

;; ================= 5. 交互：点击文件树 =================
;; 屏幕坐标 → 树 buffer 坐标（宿主自己做 hit / 命令）
(define-values (line col) (view-screen-position->point tree-v 2 4))
(displayln (list "点击 (row=2 col=4) → 树行/列" line col))
