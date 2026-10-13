#lang racket

;;; edit4/plugins/sync/sync.rkt —— 同步引擎（钩子）+ 命令
;;;
;;; 双向：哪边触发就以哪边为源，变换后写到 peer document。程序化写不 emit 钩子
;;; （钩子是 content/edit 的命令发的）→ 天然无回环。
;;; 同步写走 assign!（整篇、封存 history）→ peer 视为派生，不进 undo。

(provide sync-commands sync-hooks sync-from)

(require racket/list
         "../../core/world.rkt" "../../core/command.rkt" "../../core/hook.rkt"
         "../../layout.rkt"
         "../../content/model.rkt" "../../content/adapter.rkt"
         "mapping.rkt" "transform.rkt" "session.rkt")

;;; ---------- 同步核心 ----------

(define (first-view ed did)
  (for/first ([v (in-list (document-view-list ed did))]) v))

;; 以 vid 所属文档为源：transform 到 peer + 写回 + 搬光标。caret? = 是否也同步光标。
(define (sync-from w vid [caret? #t])
  (define c (world-content w))
  (cond
    [(not c) w]
    [else
     (define ed (content-ed c))
     (define s-did (content-did-of c vid))
     (define s (and s-did (session-for-did w s-did)))
     (cond
       [(not s) w]
       [else
        (define m (mapping-by-id (session-mapping-id s)))
        (define dir (if (eqv? s-did (session-a s)) 'a->b 'b->a))
        (define p-did (peer-did s s-did))
        (define pv (first-view ed p-did))
        (define src (document-string ed s-did))
        (define-values (dst-new edits) (translate/edits m dir src))
        (cond
          [(not pv) w]
          [else
           (define dst-old (document-string ed p-did))
           (unless (equal? dst-new dst-old) (assign! ed pv dst-new))
           (when caret?
             (define pt (map-caret edits (cons (view-line ed vid) (view-col ed vid))))
             (set-point! ed pv (car pt) (cdr pt)))
           w])])]))

;;; ---------- 钩子 ----------

(define (on-edit w args) (sync-from w (car args) #t))
(define (on-nav w args) (sync-from w (car args) #t))

(define sync-hooks
  (list (reaction* 'after-insert on-edit)
        (reaction* 'after-edit on-edit)
        (reaction* 'after-nav on-nav)
        (reaction* 'focus-changed (lambda (w args) (sync-from w (car args) #t)))))

;;; ---------- 命令 ----------

(define (editor-next wins cur)
  (cond
    [(null? wins) #f]
    [else
     (define i (or (for/first ([x (in-list wins)] [k (in-naturals)] #:when (eqv? x cur)) k) 0))
     (list-ref wins (modulo (add1 i) (length wins)))]))

(define (target-of wins cur x)
  (cond
    [(eq? x 'focus) cur]
    [(eq? x 'next) (editor-next wins cur)]
    [else x]))

;; 已显示的 did 的窗口 id（有多个取第一个）。
(define (window-of-did c did)
  (for/first ([(id vid) (in-hash (content-bindings c))]
              #:when (and vid (eqv? did (content-did-of c vid))))
    id))

;; 打开 did：已在某窗 → 聚焦；否则在焦点窗旁新开一个编辑区。
(define (reveal-doc! w did)
  (define c (world-content w))
  (define ed (content-ed c))
  (define id (window-of-did c did))
  (cond
    [id (world-set-focus w id)]
    [else
     (define pv (for/first ([v (in-list (document-view-list ed did))]) v))
     (cond
       [(not pv) w]
       [else
        (define f (world-focus w))
        (define lay (world-layout w))
        (define nid (fresh-id lay))
        (define sz (size 40 #f))
        (define nlay (if (and f (has-id? w f))
                         (insert-adjacent lay f 'right sz (leaf nid (cons 2 2)))
                         (insert-side lay 'right sz (leaf nid (cons 2 2)))))
        (define w1 (world-set-layout w nlay))
        (world-set-focus (world-set-content w1 (content-bind (world-content w1) nid pv)) nid)])]))

;; C-o o：打开焦点文档的翻译文档——已配对则打开它（新编辑区或聚焦已有窗）；
;; 否则按内容判方向翻译一份新内存文档、配对、并新开一个编辑区。
(define (h-sync-open ctx w args)
  (define c (world-content w))
  (define lay (world-layout w))
  (define f (world-focus w))
  (define did (and c f (content-did-of c f)))
  (cond
    [(not (and c f did (memv f (content-editor-windows c lay)))) #f]
    [else
     (define s (session-for-did w did))
     (cond
       [s (cons (reveal-doc! w (peer-did s did)) '())]     ; 已存在 → 打开
       [else
        (define ed (content-ed c))
        (define m (mapping-by-id (if (pair? args) (car args) 'rkt-zh)))
        (define src (document-string ed did))
        (define dir (detect-direction m src))
        (define dst (translate m dir src))
        (define peer-name (format "*~a·译*" (document-name ed did)))
        (define-values (c* p-did _p-vid) (content-add-doc! c dst 60 22 peer-name #f))
        (define w1 (world-set-content w c*))
        (define sess (if (eq? dir 'a->b)
                         (session (fresh-session-id w1) did p-did (car m))
                         (session (fresh-session-id w1) p-did did (car m))))
        ;; 建对时即把 peer 光标搬到源光标的对应位置（同构的 view 同步从这一刻成立）。
        (cons (sync-from (reveal-doc! (session-add w1 sess) p-did) f) '())])]))

;; link 两个编辑器窗的文档（a = a-lang 侧，默认焦点；b = b-lang 侧，默认下一个）。
(define (h-sync-link ctx w args)
  (define c (world-content w))
  (define lay (world-layout w))
  (define wins (content-editor-windows c lay))
  (define cur (world-focus w))
  (define a (target-of wins cur (car args)))
  (define b (target-of wins cur (cadr args)))
  (cond
    [(not (and a b (memv a wins) (memv b wins) (not (eqv? a b)))) #f]
    [else
     (define ad (content-did-of c a))
     (define bd (content-did-of c b))
     (cond
       [(not (and ad bd)) #f]
       [else
        (define mid (if (pair? (cddr args)) (caddr args) 'rkt-zh))
        (define w1 (session-add w (session (fresh-session-id w) ad bd mid)))
        (cons (sync-from w1 a #t) '())])]))

;; 解除焦点文档所在的 session。
(define (h-sync-unlink ctx w args)
  (define c (world-content w))
  (define id (world-focus w))
  (define did (and c id (content-did-of c id)))
  (cond
    [(not (and did (session-for-did w did))) #f]
    [else (cons (session-remove-did w did) '())]))

(define sync-commands
  (make-command-registry
   (list (cons 'sync-open h-sync-open)
         (cons 'sync-link h-sync-link)
         (cons 'sync-unlink h-sync-unlink))))
