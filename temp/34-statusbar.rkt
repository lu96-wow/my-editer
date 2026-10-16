#lang racket

;;; 34-statusbar.rkt —— 底部共享槽：状态栏 / 输入栏（内置 chrome）
;;;
;;;   racket temp/34-statusbar.rkt          # 进 TUI（显示状态栏）
;;;   racket temp/34-statusbar.rkt check    # headless 自检（用 API 切输入/状态栏）
;;;
;;; 编辑区下方一个固定 leaf（role='slot'），同一时刻只挂一个内存文档 view：
;;;   'status  → 状态栏（不可编辑；镜像 world.status）
;;;   'input   → 输入栏（可编辑；slot-show-input 记住焦点、聚焦槽）
;;; 两者共享同一位置。**切换由框架/API 驱动，不开放给用户手动切**：
;;;   (slot-show-input) / (slot-show-status) / (slot-show key)。
;;; 这里的输入栏自带 Esc 取消（输入会话的一部分），但"打开输入栏"只走 API。

(require tui
         "../core/editor.rkt"
         "../edit-tui/theme/main.rkt"
         "../edit-tui/core-render/main.rkt"
         "../edit-tui/command/main.rkt"
         "../edit-tui/layout/main.rkt"
         "../edit-tui/app/api/main.rkt")

;;; ════════════════ 文档（都是内存 buffer） ════════════════

(define-doc-kind! 'text   #:keymaps (list edit-keys motion-keys pointer-keys))
(define-doc-kind! 'status #:keymaps '())                        ; 状态栏不可编辑
(define input-keys
  (keys
   [(key 'escape) (λ (ctx) (slot-show-status))]                 ; 输入会话：取消
   [(key 'q 'ctrl) (λ (ctx) (quit))]))
(define-doc-kind! 'input #:keymaps (list edit-keys motion-keys pointer-keys input-keys))

(define res (make-resources))
(define-values (eb eview) (open-document! res "main.rkt" "edit me\n" #:kind 'text))
(define-values (_sb sview) (make-document "*status*" "" #:kind 'status))   ; 内存，不登记
(define-values (_ib iview) (make-document "*input*"  "" #:kind 'input))

;;; ════════════════ 布局：编辑区 + 底部固定槽 ════════════════

(define (base-world)
  (make-world #:area (rect 0 0 60 12)
              #:layout (lay 'tb
                            (pane 'editor #:view eview #:size 4 #:dock 'center #:role 'editor)
                            (pane 'slot   #:view #f    #:size 1 #:borders '()      #:role 'slot))
              #:focus (leaf-ref 'editor)
              #:status " NORMAL  main.rkt "
              #:keytable (make-keytable)))            ; 不给用户开输入栏的键

;; 安装槽：members 第一项 = 默认显示（状态栏）
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
(define (check label ok?)
  (if ok? (printf "  ✓ ~a\n" label) (error 'check "~a 失败" label)))
(define (w) (unbox world*))

;; 折叠 update intent；执行 edit/select/invoke。
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
  (check "初始显示状态栏" (eq? (slot-active (w)) 'status))
  (check "槽 leaf 在编辑区下方"
         (let-values ([(pls _c _x) (tree-solve (world-layout (w)) (world-area (w)))])
           (define er (cadr (assq 'editor pls))) (define sr (cadr (assq 'slot pls)))
           (>= (rect-y sr) (+ (rect-y er) (rect-h er) -1))))

  ;; 框架/API 打开输入栏（不是用户按键）
  (apply-intents! (slot-show-input))
  (check "API 切到输入栏" (eq? (slot-active (w)) 'input))
  (check "API 后焦点在槽" (equal? (leaf-ref 'slot) (world-focus (w))))

  ;; 输入栏可打字（进 input buffer，不碰编辑区）
  (feed! (plain #\h)) (feed! (plain #\i))
  (check "输入栏可编辑" (string=? (buffer-string (view-buffer iview)) "hi"))
  (check "编辑区未被写" (string=? (buffer-string eb) "edit me\n"))

  ;; API/输入会话结束：回状态栏 + 恢复焦点
  (apply-intents! (slot-show-status))
  (check "API 回状态栏" (eq? (slot-active (w)) 'status))
  (check "API 回后焦点回编辑区" (equal? (leaf-ref 'editor) (world-focus (w))))

  ;; 输入会话自带 Esc 取消（会话的一部分，不是用户手动切栏）
  (apply-intents! (slot-show-input))
  (feed! (plain 'escape))
  (check "输入会话 Esc 取消 → 回状态栏" (eq? (slot-active (w)) 'status))
  (check "Esc 取消后焦点回编辑区" (equal? (leaf-ref 'editor) (world-focus (w))))

  ;; world.status → 状态栏 buffer（status-sync!）
  (set-box! world* (world-set-status (w) "hello status"))
  (status-sync! (w))
  (check "状态栏镜像 world.status"
         (string=? (buffer-string (view-buffer sview)) "hello status"))

  (displayln "statusbar: 自检 OK"))
