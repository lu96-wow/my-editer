#lang racket

;;; ============================================================================
;;; lab/tui.rkt —— 终端适配器（**不属于 core，也不含业务逻辑**）
;;; ============================================================================
;;;
;;;   racket lab/tui.rkt
;;;
;;; 这里只剩三件事：
;;;   1) 把终端事件翻译成 stroke（key.rkt）；
;;;   2) dispatch（keymap 栈 → intent）+ command-step（intent → session）；
;;;   3) 把 host-frame 的增量渲染成终端字节。
;;;
;;; 「哪个键干什么」在 bindings.rkt；「干了会怎样」在 command.rkt；
;;; 「状态长什么样」在 session.rkt。本文件不认识其中任何策略。
;;;
;;; 布局：左「文件树」| 中「单编辑格」| 底「状态栏」。

(require (except-in tui cursor-col)
         "../core/editor.rkt"
         "../core/text/document.rkt"
         "../core/view/base/screen.rkt"
         "../core/view/patch.rkt"
         "layout.rkt"
         "host.rkt"
         "fs.rkt"
         "status.rkt"
         "tree.rkt"
         "workspace.rkt"
         "intent.rkt"
         "key.rkt"
         "keymap.rkt"
         "modes.rkt"
         "dispatch.rkt"
         "session.rkt"
         "command.rkt"
         "bindings.rkt")

;;; ---------- 会话（唯一可变盒子） ----------

(define session-box (box #f))
(define screen-box (box #f))              ; 最近一帧（测试 / 调试）
(define (cur) (unbox session-box))

;;; ---------- 主题：face / overlay → 真彩色 ----------
;;; core 的 face 是不透明值；这里才把它翻成 RGB。加配色只动这里。

(define (rgb-fg-bytes rgb) (if rgb (apply format-rgb-fg-base rgb) #""))
(define (rgb-bg-bytes rgb) (if rgb (apply format-rgb-bg-base rgb) #""))

(define (face-colors face)
  (cond [(not face)                (values #f #f)]
        [(eq? face 'line-number)   (values '(90 96 110) #f)]
        [(eq? face 'separator)     (values '(80 85 95) #f)]
        [(eq? face 'comment)       (values '(106 153 85) #f)]
        [(eq? face 'str)           (values '(206 145 120) #f)]
        [(eq? face 'num)           (values '(209 154 102) #f)]
        [(eq? face 'type)          (values '(229 192 123) #f)]
        [(eq? face 'fn)            (values '(97 175 239) #f)]
        [(eq? face 'kw)            (values '(198 120 221) #f)]
        [(eq? face 'status)        (values '(225 225 225) '(40 44 52))]
        [(eq? face 'tree-dir)      (values '(120 180 240) #f)]
        [(eq? face 'tree-file)     (values '(200 200 200) #f)]
        [(eq? face 'tree-open)     (values '(150 210 150) #f)]
        [else                      (values '(205 205 205) #f)]))

(define (overlay-colors ov)
  (case ov
    [(selection) (values #f '(58 74 128))]
    [else        (values #f #f)]))

(define (style-bytes attr)
  (define ov (and (pair? attr) (car attr)))
  (define face (if (pair? attr) (cdr attr) attr))
  (cond
    [(eq? ov 'cursor) format-reverse]
    [else
     (define-values (fg bg) (face-colors face))
     (define-values (ofg obg) (overlay-colors ov))
     (bytes-append (rgb-fg-bytes (or ofg fg)) (rgb-bg-bytes (or obg bg)))]))

;;; ---------- 帧 → 终端字节 ----------

(define (render-frame!)
  (define s (cur))
  (define old (host-last-screen (session-host s)))
  (define-values (h1 screen render selection) (host-frame (session-host s)))
  (set-box! session-box (session-set-host s h1))
  (set-box! screen-box screen)
  (values old screen render selection))

(define (draw!)
  (define-values (old new render selection) (render-frame!))
  (define parts '())
  (define (add! b) (set! parts (cons b parts)))
  (add! format-cursor-hide)
  (when (or (not old)
            (not (= (screen-width old) (screen-width new)))
            (not (= (screen-height old) (screen-height new))))
    (add! format-screen-clear))
  (for ([p (in-list (append render selection))])
    (add! (bytes-append (format-cursor-move (add1 (piece-row p)) (add1 (piece-col p)))
                        (style-bytes (piece-attr p))
                        (format-content (piece-text p))
                        format-reset)))
  (put-bytes (apply bytes-append (reverse parts)))
  (flush!))

(define (composed-screen)
  (define-values (_old screen _render _selection) (render-frame!))
  screen)

;;; ---------- 输入：stroke → intent → command ----------

;; 一次输入：解析键位栈 → 产出意图 → 交给命令层 → 重绘。
(define (handle! st)
  (define s (cur))
  (define it (dispatch (session-keymaps s) st (session-focus-vid s)))
  (when it
    (set-box! session-box (command-step (session-enqueue s it)))
    (draw!)))

;; 鼠标：命中 pane 后转成 input/* 意图（点击定位 / Alt 加光标 / 滚轮滚动）。
(define (handle-mouse! action button x y mods)
  (define s (cur))
  (define mx (max 0 (sub1 x)))
  (define my (max 0 (sub1 y)))
  (define-values (vid r c) (host-view-at (session-host s) my mx))
  (when vid
    (define it
      (case action
        [(press) (if (mods-alt? mods)
                     (make-intent 'input/add-cursor (list vid r c) vid)
                     (make-intent 'input/click (list vid r c) vid))]
        [(scroll) (make-intent 'input/scroll (list (if (eq? button 'up) -3 3)) vid)]
        [else #f]))
    (when it
      (set-box! session-box (command-step (session-enqueue s it)))
      (draw!))))

;; 终端事件 → stroke：文本走 char/'text token，按键走 key-token。
(define (make-handler)
  (build-input
   #:text    (lambda (s) (handle! (make-stroke-text s)))
   #:key     (lambda (name mods)
               (handle! (make-stroke (key-token name (mods-ctrl? mods) (mods-alt? mods) (mods-shift? mods)))))
   #:mouse   (lambda (action button x y mods) (handle-mouse! action button x y mods))
   #:resize  (lambda (rows cols)
               (set-box! session-box (session-resize (cur) rows cols))
               (draw!))))

;;; ---------- 组装 / 主循环 ----------

;; 树（左）| 编辑格（中）| 状态栏（底），并登记每个文档的键位。
(define (setup! rows cols #:root [root (current-directory)] #:fs [fs (fs-real)])
  (define ch (max 1 (sub1 rows)))
  (define ed0 (editor-open "" 40 ch #:line-numbers? #t))
  (define h0 (host-open ed0 rows cols))
  (define-values (h1 eid) (host-adopt-view h0 0))                     ; 编辑格（scratch）
  (define-values (h2 tid) (host-add-document h1 "" 30 ch "*tree*"      ; 文件树组件
                                             #:history? #f
                                             #:sync tree-sync
                                             #:state (tree-open root fs)))
  (define-values (h3 sid) (host-add-document h2 "" cols 1 "*status*"   ; 状态栏组件
                                             #:history? #f
                                             #:sync status-sync
                                             #:state (status "" #f)))
  (define s0 (session-open h3 (ws-empty) global-keymap))
  (define s1 (session-set-ids s0 tid sid eid))
  (define (did-of s id) (editor-view-document-id (host-editor (session-host s)) (session-pane-vid s id)))
  ;; 每个文档登记自己的键位（这就是「每文档独立键绑定」的落点）
  (define s2 (session-set-mode (session-set-mode s1 (did-of s1 tid) tree-keymap)
                               (did-of s1 eid) editor-keymap))
  (define s3 (session-set-host s2 (host-set-layout (session-host s2) (session-layout s2))))
  (set-box! session-box (session-set-focus s3 eid))
  (set-box! screen-box #f))

(module+ main
  (with-tui
   (lambda ()
     (define-values (r c) (get-window-size))
     (setup! (max 2 (or r 24)) (max 1 (or c 80)))
     (draw!)
     (loop-input/stop (session-quit? (cur)) (make-handler)))))

;;; ---------- 无 TTY 冒烟测试 ----------

(module+ test
  (require rackunit racket/file
           "../core/text/base/point.rkt" "intent.rkt")

  (define nowhere (open-output-nowhere))
  (define dir (make-temporary-file "tuidir-~a" 'directory))
  (define sub (build-path dir "sub"))
  (make-directory sub)
  (define tmp (build-path dir "a.txt"))
  (define ms (build-path dir "b.txt"))
  (display-to-file "FILE CONTENT\nsecond line\n" tmp #:exists 'replace)
  (display-to-file "foo bar\nfoo baz\nfoo\n" ms #:exists 'replace)

  (define (s) (cur))
  (define (ed) (host-editor (session-host (s))))
  (define (evid) (host-pane-vid (session-host (s)) (session-editor-id (s))))
  (define (tid) (session-tree-id (s)))
  (define (tv) (host-pane-vid (session-host (s)) (tid)))
  (define (tst) (session-pane-state (s) (tid)))
  (define (tree-focused?) (equal? (session-focus-id (s)) (tid)))
  (define (prompting?) (session-mode-active? (s)))
  (define (cur-entry) (tree-line-entry (tst) (editor-view-point-line (ed) (tv))))
  (define (ps p) (path->string p))

  (setup! 20 80 #:root dir #:fs (fs-real))
  (define h (make-handler))

  ;; 布局：树 | 编辑格 | 状态栏
  (define s0 (composed-screen))
  (check-equal? (screen-width s0) 80)
  (check-equal? (screen-height s0) 20)
  ;; 根行显示绝对路径
  (check-true (for/or ([rn (in-list (screen-row s0 0))]) (regexp-match? #rx"tuidir" (run-text rn))))
  (check-true (for/or ([rn (in-list (screen-row s0 0))]) (>= (run-col rn) 31)))
  (check-true (for/or ([rn (in-list (screen-row s0 19))]) (eq? (run-face rn) 'status)))

  (parameterize ([current-output-port nowhere])
    ;; 初始焦点在编辑格：打字进入编辑格
    (h (key-event #\X (mods #f #f #f)))
    (check-equal? (substring (editor-view-string (ed) (evid)) 0 1) "X")

    ;; Ctrl+O 切到文件树；方向键 = 普通光标移动
    (h (key-event #\o (mods #t #f #f)))
    (check-true (tree-focused?))
    (check-equal? (ps (entry-path (cur-entry))) (ps dir))            ; 初始光标在根行
    (h (key-event 'down (mods #f #f #f)))                            ; → sub
    (check-equal? (ps (entry-path (cur-entry))) (ps sub))
    (h (key-event 'down (mods #f #f #f)))                            ; → a.txt
    (check-equal? (ps (entry-path (cur-entry))) (ps tmp))
    ;; 回车打开文件（焦点自动回编辑格）
    (h (key-event 'enter (mods #f #f #f)))
    (check-equal? (editor-view-string (ed) (evid)) "FILE CONTENT\nsecond line\n")
    (check-true (ws-open? (session-ws (s)) tmp))
    (check-false (tree-focused?))

    ;; ---------- 建 / 删 ----------
    (h (key-event #\o (mods #t #f #f)))                              ; 焦点回树（光标仍在 a.txt）
    (h (key-event 'up (mods #f #f #f)))                              ; → sub
    (check-equal? (ps (entry-path (cur-entry))) (ps sub))
    (h (key-event #\n (mods #f #f #f)))                              ; 命名提示
    (check-true (prompting?))
    (h (key-event 'enter (mods #f #f #f)))                           ; 确认名字 → 写入确认
    (check-true (prompting?))
    (h (key-event #\y (mods #f #f #f)))                              ; 确认写入
    (h (key-event 'enter (mods #f #f #f)))
    (check-false (prompting?))
    (define made (build-path sub "untitled"))
    (check-true (file-exists? made))
    (check-equal? (ps (entry-path (cur-entry))) (ps made))           ; 光标落到新项
    (h (key-event #\d (mods #f #f #f)))                              ; 删文件：需确认
    (check-true (prompting?))
    (check-true (file-exists? made))
    (h (key-event #\y (mods #f #f #f)))
    (h (key-event 'enter (mods #f #f #f)))
    (check-false (file-exists? made))

    ;; 删目录：需确认；Esc 取消，输入 y 才删（焦点仍在树上）
    ;; 光标移到 sub 行
    (define (goto-line! line)
      (set-box! session-box
                (session-set-editor (s)
                  (editor-view-set-point (ed) (tv) (point line 0)))))
    (define (line-of path)
      (for/first ([v (in-list (tree-visible (tst)))] [i (in-naturals)]
                  #:when (equal? (entry-path (cdr v)) path)) i))
    (goto-line! (line-of sub))
    (h (key-event #\d (mods #f #f #f)))
    (check-true (prompting?))
    (check-true (directory-exists? sub))                             ; 还没删
    (h (key-event 'escape (mods #f #f #f)))                          ; 取消
    (check-false (prompting?))
    (check-true (directory-exists? sub))
    (h (key-event #\d (mods #f #f #f)))                              ; 再来，输入 y 回车
    (check-true (prompting?))
    (h (key-event #\y (mods #f #f #f)))
    (h (key-event 'enter (mods #f #f #f)))
    (check-false (prompting?))
    (check-false (directory-exists? sub))

    ;; 根目录：禁删
    (goto-line! 0)
    (h (key-event #\d (mods #f #f #f)))
    (check-true (directory-exists? dir))
    (check-false (prompting?))

    ;; 删除已打开的文件 → 关文档 + 编辑格换空 scratch
    (set-box! session-box (command-step (session-enqueue (s) (make-intent 'file/open (list ms)))))
    (check-true (ws-open? (session-ws (s)) ms))
    (h (key-event #\o (mods #t #f #f)))
    (goto-line! (line-of ms))
    (check-equal? (ps (entry-path (cur-entry))) (ps ms))
    (h (key-event #\d (mods #f #f #f)))
    (check-true (file-exists? ms))                                   ; 还没删
    (h (key-event #\y (mods #f #f #f)))
    (h (key-event 'enter (mods #f #f #f)))
    (check-false (file-exists? ms))
    (check-false (ws-open? (session-ws (s)) ms))
    (check-equal? (editor-view-string (ed) (evid)) "")

    ;; ---------- 编辑格多选区 ----------
    (set-box! session-box (command-step (session-enqueue (s) (make-intent 'file/open (list tmp)))))
    (h (key-event #\d (mods #t #f #f)))                              ; 选词
    (h (key-event #\X (mods #f #f #f)))
    (check-equal? (substring (editor-view-string (ed) (evid)) 0 6) "X CONT")

    ;; resize
    (h (resize-event 14 50))
    (let ([s1 (composed-screen)])
      (check-equal? (screen-width s1) 50)
      (check-equal? (screen-height s1) 14)))

  (delete-directory/files dir)
  (displayln "lab/tui.rkt: all tests passed"))
