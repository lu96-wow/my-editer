#lang racket

;;; 31 —— 语法补全浮层：浮窗 + 临时操作表，浮窗永不占焦点
;;;
;;;   racket temp/31-completion.rkt          # 进 TUI
;;;   racket temp/31-completion.rkt check    # headless 自检
;;;
;;; 流程：TAB 弹出候选浮窗并挂一张临时表（↑/↓/Enter/Esc 遮蔽编辑区同名键）→
;;;       选中后 Enter 把候选插进**编辑区焦点**，同时关窗 + 拆表；Esc 只关不插。
;;;
;;; 关键点：
;;;   · 浮层 = 浮窗 + 同名临时拓展层表（key = 'completion），open-overlay / close-overlay 成对；
;;;   · 拓展层在 active-keytables 最高，所以 ↑/↓/Enter 被临时表遮蔽（不会走编辑区）；
;;;   · world-focus-on 只接受 leaf → 浮窗永不占焦点，打字/落点始终在编辑区；
;;;   · 拥有活动拓展层的浮窗 view 会被 world-overlay-views 选出 → core 画它的选区高亮。

(require tui
         "../core/editor.rkt"
         "../edit-tui/theme/main.rkt"
         "../edit-tui/core-render/main.rkt"
         "../edit-tui/command/main.rkt"
         "../edit-tui/layout/main.rkt"
         "../edit-tui/app/api/main.rkt")

;;; ════════════════ 文档 ════════════════

(define-doc-kind! 'text       #:keymaps (list edit-keys motion-keys pointer-keys))
(define-doc-kind! 'completion #:keymaps '())          ; 浮窗自己的表：空（交互走拓展层表）

(define res (make-resources))
(define-values (eb eview) (open-document! res "main.rkt" "\n" #:kind 'text))

(define candidates '("alpha" "beta" "gamma"))
(define-values (cb cview)
  (open-document! res "*completions*"
                  (string-append (string-join candidates "\n") "\n")
                  #:kind 'completion))

;;; ════════════════ 浮层：浮窗 + 临时表 ════════════════

(define overlay-key 'completion)
(define (overlay-view w)
  (world-ref->view w (float-ref overlay-key)))

;; 把第 line 行整行选起来（渲染成一条高亮）。
;; 浮窗 view 在 panels-sync! 之前还是 1×1，不能走默认的 ensure（会把 left-column
;; 水平滚走），所以用 invoke + view-set-selections! #:ensure? #f。
(define (select-line v line)
  (list (invoke (λ ()
                  (view-set-selections!
                   v
                   (selections-one
                    (selection (point line 0)
                               (point line (string-length (list-ref candidates line)))))
                   #:ensure? #f)))))
(define (completion-select ctx line)
  (define fv (overlay-view (ctx-world ctx)))
  (if fv (select-line fv line) '()))
(define (completion-move ctx delta)
  (define fv (overlay-view (ctx-world ctx)))
  (if fv
      (completion-select ctx (max 0 (min (+ (view-point-line fv) delta)
                                         (sub1 (length candidates)))))
      '()))
(define (completion-accept ctx)
  (define fv (overlay-view (ctx-world ctx)))
  (define text (if fv (list-ref candidates (view-point-line fv)) ""))
  (append (focus-insert ctx text)        ; 插进编辑区焦点
          (close-overlay overlay-key)))  ; 关窗 + 拆表
(define (completion-cancel ctx) (close-overlay overlay-key))

(define completion-keys
  (keys
   [(key 'down)   (λ (ctx) (completion-move ctx +1))]
   [(key 'up)     (λ (ctx) (completion-move ctx -1))]
   [(key 'enter)  completion-accept]
   [(key 'escape) completion-cancel]))

;; 光标下方弹窗；光标不可见就退回左上角。
(define (overlay-rect w v)
  (define ep (world-ref->panel w (world-focus w)))
  (define-values (cr cc) (view-cursor-screen-position v))
  (define-values (sr sc) (if (and ep cr) (panel-content->screen ep cr cc) (values 1 1)))
  (float-rect-at sr sc 20 (+ (length candidates) 2) (world-area w)))

(define (start-completion ctx)
  (define w (ctx-world ctx))
  (define v (ctx-view ctx))
  (if (overlay-view w)
      '()                                    ; 已开
      (append (open-overlay overlay-key
                            (make-float overlay-key cview (overlay-rect w v))
                            (make-keytable completion-keys))
              (select-line cview 0))))       ; 新窗用 cview 直接建选区

;;; ════════════════ 命令 ════════════════

(define global-keys
  (keys
   [(key 'tab)     start-completion]
   [(key 'q 'ctrl) (λ (ctx) (quit))]))

(define (make-app-world)
  (make-world #:area (rect 0 0 80 24)
              #:layout (pane 'editor #:view eview #:borders '() #:role 'editor)
              #:focus (leaf-ref 'editor)
              #:keytable (make-keytable global-keys)))

;;; ════════════════ 入口 ════════════════

(module+ main
  (define args (current-command-line-arguments))
  (if (and (positive? (vector-length args)) (equal? (vector-ref args 0) "check"))
      (run-check!)
      (run-app (make-app-world))))

;;; ════════════════ headless 自检 ════════════════

(define world* (box #f))
(define (plain c) (key-event c (mods #f #f #f)))
(define (check label ok?)
  (if ok? (printf "  ✓ ~a\n" label) (error 'check "~a 失败" label)))

;; world-step* 折叠 update intent；这里再执行 demo 用到的 effect intent。
(define (feed! ev)
  (define-values (w is) (world-step* (unbox world*) (list ev)))
  (set-box! world* w)
  (for ([i (in-list is)])
    (match i
      [(edit v op)    (buffer-edit! (view-buffer v) v op)]
      [(select v sel) (view-set-selections! v sel)]
      [(invoke th)    (th)]))
  is)

(define (w) (unbox world*))
(define (float-line)
  (define fv (overlay-view (w)))
  (and fv (view-point-line fv)))

(define (run-check!)
  (set-box! world* (make-app-world))
  (feed! (plain 'tab))
  (check "TAB：浮窗出现" (not (equal? #f (overlay-view (w)))))
  (check "TAB：临时表已挂" (= 1 (length (world-layers (w)))))
  (check "TAB：焦点仍在编辑区" (equal? (leaf-ref 'editor) (world-focus (w))))
  (check "TAB：默认选第 0 个候选" (= 0 (float-line)))
  (check "overlay views = 编辑区 + 浮窗" (= 2 (length (world-overlay-views (w)))))

  (feed! (plain 'down))
  (check "↓：临时表遮蔽编辑区，候选下移" (= 1 (float-line)))
  (check "↓：编辑区光标没动（焦点 view 行仍 0）" (= 0 (view-point-line eview)))
  (feed! (plain 'down)) (feed! (plain 'down))
  (check "↓ 到底夹住" (= 2 (float-line)))
  (feed! (plain 'up))
  (check "↑ 上移" (= 1 (float-line)))

  (feed! (plain 'enter))
  (check "Enter：候选插进编辑区" (string=? (buffer-string eb) "beta\n"))
  (check "Enter：浮窗关闭" (equal? #f (overlay-view (w))))
  (check "Enter：临时表拆掉" (null? (world-layers (w))))
  (check "Enter：焦点仍在编辑区" (equal? (leaf-ref 'editor) (world-focus (w))))

  ;; Esc 只关不插
  (feed! (plain 'tab))
  (feed! (plain 'escape))
  (check "Esc：浮窗关闭" (equal? #f (overlay-view (w))))
  (check "Esc：临时表拆掉" (null? (world-layers (w))))
  (check "Esc：正文未被插入" (string=? (buffer-string eb) "beta\n"))

  (displayln "completion: 自检 OK"))
