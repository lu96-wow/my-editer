#lang racket

;;; 34-statusbar.rkt —— 状态栏（行列 / 路径 / 键序列）+ 输入栏（minibuffer）
;;;
;;;   racket temp/34-statusbar.rkt          # 进 TUI
;;;   racket temp/34-statusbar.rkt check    # headless 自检
;;;
;;; 状态栏 = 焦点 view 的行列 + 焦点 buffer 路径（若有）+（键序列 | 状态消息）。
;;; 键序列（world.pending）优先；命中命令 / 未命中后清空。
;;; 带 #:input 的命令在触发时**自动**切到输入栏，Enter 提交 / Esc 取消后回状态栏。

(require racket/string
         tui
         "../core/editor.rkt"
         "../edit-tui/theme/main.rkt"
         "../edit-tui/core-render/main.rkt"
         "../edit-tui/command/main.rkt"
         "../edit-tui/layout/main.rkt"
         "../edit-tui/app/api/main.rkt")

;;; ════════════════ 文档（状态/输入都是内存 buffer） ════════════════

(define-doc-kind! 'text   #:keymaps (list edit-keys motion-keys pointer-keys))
(define-doc-kind! 'status #:keymaps '())

;; 输入栏：可编辑，但 Enter/Esc 归 minibuffer（不要合并含 enter 的 edit-keys）
(define input-edit-keys
  (keys [(key 'backspace) focus-delete-backward]
        [(key 'delete)    focus-delete-forward]))
(define-doc-kind! 'input #:keymaps (list motion-keys pointer-keys input-edit-keys minibuffer-keys))

(define res (make-resources))
(define-values (eb eview)
  (open-document! res "main.rkt" "edit me\n" #:kind 'text #:path "/home/me/main.rkt"))
(define-values (_sb sview) (make-document "*status*" "" #:kind 'status))   ; 内存，无路径
(define-values (_ib iview) (make-document "*input*"  "" #:kind 'input))

;;; ════════════════ 命令 ════════════════

;; 带 #:input：触发时自动切输入栏；提交后显示 "got: <值>"
(define ask-keys
  (keys
   [(key 'f 'alt)
    (cmd (λ (v) (show-status (format "got: ~a" v)))
         #:input (input 'string "name: " #f))]))

;; 两步键序列：C-x C-s；C-x 之后按别的是未命中
(define prefix-keys
  (keys
   [(key 'x 'ctrl) (key 's 'ctrl) (λ (ctx) (show-status "saved"))]
   [(key 'x 'ctrl) (key 'q 'ctrl) (λ (ctx) (quit))]))

;;; ════════════════ 布局：编辑区 + 底部固定槽 ════════════════

(define (base-world)
  (make-world #:area (rect 0 0 60 12)
              #:layout (lay 'tb
                            (pane 'editor #:view eview #:size 1 #:dock 'center #:role 'editor)
                            (pane 'slot   #:view #f    #:fixed 1 #:borders '()     #:role 'slot))
              #:focus (leaf-ref 'editor)
              #:keytable (make-keytable ask-keys prefix-keys)))

(define (boot)
  (slot-install (base-world) 'slot (list (cons 'status sview) (cons 'input iview))))

;;; ════════════════ 入口 ════════════════

(module+ main
  (define args (current-command-line-arguments))
  (if (and (positive? (vector-length args)) (equal? (vector-ref args 0) "check"))
      (run-check!)
      (run-app (boot))))

;;; ════════════════ headless 自检 ════════════════

(define world* (box #f))
(define (plain c) (key-event c (mods #f #f #f)))
(define (ctrl c)  (key-event c (mods #t #f #f)))
(define (alt c)   (key-event c (mods #f #t #f)))
(define (w) (unbox world*))
(define (check label ok?)
  (if ok? (printf "  ✓ ~a\n" label) (error 'check "~a 失败" label)))
(define (has? s sub) (and s (string-contains? s sub)))

(define (apply-intents! is)
  (for ([i (in-list is)]) (match i
                            [(update f d) (set-box! world* (let ([w* (f (w))]) (if d (world-mark-dirty w*) w*)))]
                            [(edit v op)    (buffer-edit! (view-buffer v) v op)]
                            [(select v sel) (view-set-selections! v sel)]
                            [(invoke th)    (th)]))
  (void))
(define (feed! ev)
  (define-values (w1 is) (world-step* (w) (list ev)))
  (set-box! world* w1)
  (apply-intents! is))

(define (run-check!)
  (set-box! world* (boot))

  ;; 1) 状态栏：行列 + 路径
  (define s0 (status-line (w)))
  (check "状态栏含行列 1:1" (has? s0 "1:1"))
  (check "状态栏含 buffer 路径" (has? s0 "/home/me/main.rkt"))

  ;; 2) 键序列：C-x 显示，C-x C-s 触发命令后清空
  (feed! (ctrl 'x))
  (check "前缀显示 C-x" (has? (status-line (w)) "C-x"))
  (feed! (ctrl 's))
  (check "命令后序列清空" (not (has? (status-line (w)) "C-x")))
  (check "命令消息 saved" (has? (status-line (w)) "saved"))

  ;; 3) 未命中：C-x 之后按 up → unbound，序列清空
  (feed! (ctrl 'x))
  (feed! (plain 'up))
  (check "未命中后序列清空" (null? (world-pending (w))))
  (check "状态栏显示 unbound" (has? (status-line (w)) "unbound"))

  ;; 4) 带 #:input 的命令：自动切输入栏 + prompt（只读前缀）
  (define focus0 (world-focus (w)))
  (feed! (alt 'f))
  (check "自动切到输入栏" (eq? (slot-active (w)) 'input))
  (check "输入栏焦点在槽" (equal? (leaf-ref 'slot) (world-focus (w))))
  (check "输入栏写入 prompt" (string-contains? (buffer-string (view-buffer iview)) "name: "))
  (check "输入值为空" (string=? (minibuffer-text (w)) ""))

  ;; 打字（可打印字符走 fallback 插入）
  (for ([c (in-string "bob")]) (feed! (plain c)))
  (check "输入值 = bob" (string=? (minibuffer-text (w)) "bob"))

  ;; Enter 提交：跑命令、回状态栏、恢复焦点、清会话
  (feed! (plain 'enter))
  (check "Enter 后回状态栏" (eq? (slot-active (w)) 'status))
  (check "Enter 后焦点回编辑区" (equal? focus0 (world-focus (w))))
  (check "命令拿到输入值" (has? (status-line (w)) "got: bob"))
  (check "会话已清" (not (minibuffer-of (w))))

  ;; 5) Esc 取消
  (feed! (alt 'f))
  (check "再次进入输入栏" (eq? (slot-active (w)) 'input))
  (feed! (plain 'escape))
  (check "Esc 取消回状态栏" (eq? (slot-active (w)) 'status))
  (check "Esc 取消后会话清" (not (minibuffer-of (w))))

  (displayln "statusbar: 自检 OK"))
