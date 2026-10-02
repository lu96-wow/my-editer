#lang racket

;;; ============================================================================
;;; host.rkt —— 通用宿主：全局状态 + 组件协议 + 帧
;;; ============================================================================
;;;
;;; 骨架里唯一持全局状态的地方。它只认识「组件协议」和「effect 词汇」，
;;; 不认识 tree、不认识任何后端。
;;;
;;;   host = editor(core) × panes × layout × focus × size
;;;   pane = { kind, vid, sync, input, pointer, focusable?, state }
;;;   ctx  = 给组件的只读快照
;;;
;;; 组件只做两件事：
;;;   sync  : ctx × state        → (values document state cursor)
;;;   input : ctx × state × input → (values state (listof effect))
;;;
;;; 会动全局结构的动作只表达成 effect，由本模块统一执行 —— 全局状态只有一个写口。

(require "../core/editor.rkt"
         "../core/text/document.rkt"
         "../core/text/base/point.rkt"
         "layout.rkt"
         "io.rkt"
         "fs.rkt"
         racket/file)

(provide
 (struct-out pane)
 (struct-out host)
 (struct-out ctx)
 host-pane host-set-pane host-pane-vid host-focus-vid host-pane-rect
 host-set-focus make-ctx
 host-opened host-path host-open host-close-document
 host-dispatch host-project! host-render apply-effects handle)

;;; ---------- 状态 ----------

(struct pane (kind vid sync input pointer focusable? state) #:transparent)
;; kind       : symbol
;; vid        : vid                       渲染到哪个 core 视图
;; sync       : #f | (ctx state → (values document state cursor))
;; input      : #f | (ctx state input → (values state (listof effect)))
;; pointer    : #f | (ctx state input 行 列 → (values state (listof effect)))
;; focusable? : bool

(struct host (editor opened panes layout focus rows cols) #:transparent)
;; editor : core editor（文档 + 视图）
;; opened : hash（path → did）
;; panes  : hash（pane-id → pane）
;; layout : layout 值（叶 = pane-id）
;; focus  : pane-id
;; rows / cols : 屏幕尺寸

(struct ctx (pid vid pane-w pane-h editor focus opened) #:transparent)
;; 组件拿到的**只读**上下文

;;; ---------- 存取 ----------

(define (host-pane h pid) (hash-ref (host-panes h) pid))
(define (host-set-pane h pid p) (struct-copy host h [panes (hash-set (host-panes h) pid p)]))
(define (host-pane-vid h pid) (pane-vid (host-pane h pid)))
(define (host-focus-vid h) (host-pane-vid h (host-focus h)))

(define (host-pane-rect h pid)
  (for/first ([r (in-list (layout-rects (host-layout h) 0 0 (host-cols h) (host-rows h)))]
              #:when (= pid (lrect-id r)))
    r))

(define (make-ctx h pid)
  (define r (host-pane-rect h pid))
  (ctx pid (host-pane-vid h pid)
       (if r (lrect-w r) 40) (if r (lrect-h r) 10)
       (host-editor h) (host-focus h) (host-opened h)))

(define (host-set-focus h pid)
  (host-pane h pid)                                   ; 校验
  (struct-copy host h [focus pid]))

;;; ---------- 文档生命周期（path ↔ did） ----------

(define (host-path h did)
  (for/first ([(p d) (in-hash (host-opened h))] #:when (= d did)) p))

;; 打开：已开→原样；否则读文件建文档。
(define (host-open h path)
  (cond
    [(hash-ref (host-opened h) path #f) h]
    [(not (and (file-exists? path) (not (directory-exists? path)))) h]
    [else
     (define-values (ed did) (editor-add-document (host-editor h) (read-text path) (name-of path)))
     (struct-copy host h
       [editor ed]
       [opened (hash-set (host-opened h) path did)])]))

(define (host-close-document h did)
  (editor-document-entry (host-editor h) did)         ; 校验
  (struct-copy host h
    [editor (editor-close-document (host-editor h) did)]
    [opened (for/hash ([(p d) (in-hash (host-opened h))] #:unless (= d did)) (values p d))]))

;;; ---------- 运行时 ----------

;; 跑每个 pane 的 sync，把文档写进它的 view（幂等；cursor 非 #f 时落点）。
(define (host-project! h)
  (for/fold ([h h]) ([pid (in-list (hash-keys (host-panes h)))])
    (define p (host-pane h pid))
    (define sync (pane-sync p))
    (cond
      [(not sync) h]
      [else
       (define-values (doc st cur) (sync (make-ctx h pid) (pane-state p)))
       (define h1 (host-set-pane h pid (struct-copy pane p [state st])))
       (cond
         [(not doc) h1]
         [else
          (editor-view-assign! (host-editor h1) (pane-vid p) doc)
          (when cur (editor-view-set-point! (host-editor h1) (pane-vid p) cur))
          h1])])))

;; 输入 → 命中 pane（鼠标）或焦点 pane（键盘）→ state + effects → 解释 effects。
(define (host-dispatch h in)
  (cond
    [(or (mouse? in) (wheel? in))
     (define-values (pr pc) (pointer-position in))
     (define pid (layout-hit (host-layout h) (host-cols h) (host-rows h) pr pc))
     (cond
       [(not pid) h]
       [else
        (define p (host-pane h pid))
        (define h1 (if (pane-focusable? p) (host-set-focus h pid) h))
        (define f (pane-pointer p))
        (cond
          [(not f) h1]
          [else
           (define r (host-pane-rect h1 pid))
           (define-values (st eff)
             (f (make-ctx h1 pid) (pane-state p) in
                (- pr (lrect-y r)) (- pc (lrect-x r))))
           (apply-effects (host-set-pane h1 pid (struct-copy pane p [state st])) eff)])])]
    [else
     (define pid (host-focus h))
     (define p (host-pane h pid))
     (define f (pane-input p))
     (cond
       [(not f) h]
       [else
        (define-values (st eff) (f (make-ctx h pid) (pane-state p) in))
        (apply-effects (host-set-pane h pid (struct-copy pane p [state st])) eff)])]))

;; effect：会把全局结构改掉的动作。组件只描述，host 统一执行。
;;   (list 'open path) | (list 'close-document did) | (list 'focus pid)
(define (apply-effects h effs)
  (for/fold ([h h]) ([e (in-list effs)]) (apply-effect h e)))

(define (apply-effect h e)
  (match e
    [(list 'open path)          (host-open h path)]
    [(list 'close-document did) (host-close-document h did)]
    [(list 'focus pid)          (host-set-focus h pid)]
    [else h]))

;; 输入入口：resize + 分发，最后投影一次（处理完状态就是对的）。
(define (handle h in)
  (host-project!
   (cond
     [(resize? in) (struct-copy host h [rows (resize-rows in)] [cols (resize-cols in)])]
     [else (host-dispatch h in)])))

;;; ---------- 帧 ----------

;; project! → layout 解析成 core rects → 尺寸落到 view → 合成 screen。→ (values host screen)
(define (host-render h)
  (define h1 (host-project! h))
  (define lrs (layout-rects (host-layout h1) 0 0 (host-cols h1) (host-rows h1)))
  (define rects (for/list ([r (in-list lrs)])
                  (rect (host-pane-vid h1 (lrect-id r))
                        (lrect-x r) (lrect-y r) (lrect-w r) (lrect-h r) 0)))
  (define ed (editor-set-layout (host-editor h1) rects))
  (define h2 (struct-copy host h1 [editor ed]))
  (values h2 (editor-render-layout ed rects (host-focus-vid h2) (host-cols h2) (host-rows h2))))

;;; ---------- 测试 ----------

(module+ test
  (require rackunit "../core/view/base/screen.rkt")

  (define d (make-temporary-file "rbhost-~a" 'directory))
  (define f (build-path d "a.txt"))
  (display-to-file "hello\n" f #:exists 'replace)

  (define ed (editor-open "" 20 5 #:line-numbers? #f))
  (define h0 (host ed (hash) (hash 0 (pane 'tree 0 #f #f #f #t #f)) (leaf 0) 0 5 20))

  ;; 帧尺寸 = host 尺寸
  (define-values (_h1 screen) (host-render h0))
  (check-equal? (list (screen-width screen) (screen-height screen)) '(20 5))

  ;; 打开 / 关闭
  (define h2 (host-open h0 f))
  (check-true (hash-has-key? (host-opened h2) f))
  (define did (hash-ref (host-opened h2) f))
  (check-equal? (document->string
                 (document-entry-document (editor-document-entry (host-editor h2) did)))
                "hello\n")
  (define h3 (host-close-document h2 did))
  (check-false (hash-has-key? (host-opened h3) f))

  ;; effect 解释
  (check-true (hash-has-key? (host-opened (apply-effects h0 (list (list 'open f)))) f))
  ;; 不存在 = no-op
  (check-equal? (host-opened (host-open h0 (build-path d "nope"))) (hash))

  (delete-directory/files d)
  (displayln "lab-rebuild/host.rkt: all tests passed"))
