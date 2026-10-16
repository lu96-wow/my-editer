#lang racket

;;; app/base-keys.rkt —— 基础命令小表（编辑 / 移动 / 指针 / 焦点）
;;;
;;; 小表分开定义（逻辑分离、可单测），合并交给 document 类型或全局：
;;;
;;;   (define-doc-kind! 'text #:keymaps (list edit-keys motion-keys pointer-keys))
;;;   (make-keytable global-keys focus-keys)   ; 焦点移动与文档类型无关，放全局
;;;
;;; 合并（keytable）是查表性能路径，热路径只读；分开是为了作者期能独立改 / 复用 /
;;; 覆盖。插件要覆盖某键，不要改这些小表，而是给 document 追加一层（见 doc-kind.rkt）。
;;;
;;; 命令是纯的：ctx → (listof intent)。这里只产出 edit / select / modify / invoke，
;;; 不直接改 core。
;;;
;;; `pointer-keys` 是**编辑器类型的鼠标行为**（下放自 step）：点哪落哪 + 起选 + 拖选。
;;; 非编辑器类型（tree/state）不合并这张表，而给自己的表加各自的鼠标命令。
;;; `focus-keys` 是**面板间焦点移动**（键盘），与文档类型无关，通常合并进全局表。
;;; 拖缝（resize）是布局 chrome，留在 step，不进这里。

(require "../command/main.rkt"
         "../../core/editor.rkt"
         "world.rkt"
         "intent.rkt")

(provide edit-keys motion-keys pointer-keys focus-keys)

;;; ---------- 通用：把命令作用到焦点 view ----------

(define (on-view ctx f)
  (define v (ctx-view ctx))
  (if v (f v) '()))

(define (insert! ctx text)
  (on-view ctx (λ (v) (list (edit v (op-type text))))))

(define (del! ctx op)
  (on-view ctx (λ (v) (list (edit v op)))))

(define (nav! ctx op)
  (on-view ctx (λ (v) (list (invoke (λ () (op v)))))))

;;; ════════════════════════ 编辑 ════════════════════════

(define edit-keys
  (keys
   [(key 'enter)     (λ (ctx) (insert! ctx "\n"))]
   [(key 'backspace) (λ (ctx) (del! ctx (op-backspace)))]
   [(key 'delete)    (λ (ctx) (del! ctx (op-delete)))]
   [(key 'z 'ctrl)   (λ (ctx) (on-view ctx (λ (v) (list (invoke (λ () (buffer-undo! (view-buffer v))))))))]
   [(key 'y 'ctrl)   (λ (ctx) (on-view ctx (λ (v) (list (invoke (λ () (buffer-redo! (view-buffer v))))))))]))

;;; ════════════════════════ 移动（光标） ════════════════════════

(define motion-keys
  (keys
   [(key 'left)  (λ (ctx) (nav! ctx view-left!))]
   [(key 'right) (λ (ctx) (nav! ctx view-right!))]
   [(key 'up)    (λ (ctx) (nav! ctx view-up!))]
   [(key 'down)  (λ (ctx) (nav! ctx view-down!))]
   [(key 'home)  (λ (ctx) (nav! ctx view-home!))]
   [(key 'end)   (λ (ctx) (nav! ctx view-end!))]))

;;; ════════════════════════ 指针（编辑器鼠标行为，下放自 step） ════════════════════════
;;; 鼠标 token 与键盘共用一张表；位置不进 token，在 ctx（panel / doc-point）。

(define pointer-keys
  (keys
   ;; 左键按下：聚焦命中面板（按 ref）→ 落光标 → 起选（drag kind='select，主体=ref）。
   [(mouse 'press 'left)
    (λ (ctx)
      (define ref (ctx-ref ctx))
      (define v   (ctx-view ctx))
      (define pt  (ctx-doc-point ctx))
      (cond
        [(and ref v pt)
         (list (modify (λ (w)
                         (define w1 (world-focus-on w ref))
                         (struct-copy world w1 [drag (drag 'select ref (list ref pt))])))
               (select v (selections-one (caret pt))))]
        [(and ref v)
         (list (modify (λ (w) (world-focus-on w ref))))]
        [else '()]))]
   ;; 移动：只有正在 select 拖动时才更新选区（主体 ref → 当帧 panel → 当帧 view）。
   [(mouse 'move #f)
    (λ (ctx)
      (define w (ctx-world ctx))
      (define d (world-drag w))
      (cond
        [(and (drag? d) (eq? (drag-kind d) 'select))
         (define ref (drag-subject d))
         (define anchor (cadr (drag-data d)))
         (define panel (world-ref->panel w ref))
         (define-values (row col) (mouse-position (ctx-event ctx)))
         (define-values (l c) (if panel
                                  (panel-screen-position->point panel row col)
                                  (values #f #f)))
         (if l
             (list (select (ctx-view ctx)
                           (selections-one (selection anchor (point l c)))))
             '())]
        [else '()]))]))

;;; ════════════════════════ 焦点移动（面板间，与文档类型无关） ════════════════════════
;;; 用 core 的 panel-neighbor（同层方向最近面板）；把邻居 panel 反查成 ref 后切焦点。
;;; 焦点是 ref，所以这里只动 world.focus，不碰 view。

(define (focus-move! ctx dir)
  (define w (ctx-world ctx))
  (define ps (world-panels w))
  (define refs (world-panel-refs w))
  (define from (for/first ([p (in-list ps)] [rf (in-list refs)]
                           #:when (equal? rf (ctx-ref ctx))) p))
  (cond
    [(not from) '()]
    [else
     (define nbr (panel-neighbor ps from dir))
     (define nbr-ref (and nbr (for/first ([p (in-list ps)] [rf (in-list refs)]
                                          #:when (eq? p nbr)) rf)))
     (if nbr-ref (list (modify (λ (w) (world-focus-on w nbr-ref)))) '())]))

(define focus-keys
  (keys
   [(key 'w 'ctrl) (key 'left)  (λ (ctx) (focus-move! ctx 'left))]
   [(key 'w 'ctrl) (key 'right) (λ (ctx) (focus-move! ctx 'right))]
   [(key 'w 'ctrl) (key 'up)    (λ (ctx) (focus-move! ctx 'up))]
   [(key 'w 'ctrl) (key 'down)  (λ (ctx) (focus-move! ctx 'down))]))
