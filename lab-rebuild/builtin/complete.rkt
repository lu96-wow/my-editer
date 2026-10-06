#lang racket

(require "../../core/editor.rkt"
         "../platform/state.rkt"
         "../platform/edit-panes.rkt"
         "../platform/paths.rkt"
         "../platform/input.rkt"
         "../platform/keymap.rkt"
         "../platform/command.rkt"
         "../platform/hooks.rkt"
         "../platform/overlay.rkt"
         "../platform/mode.rkt"
         "../platform/wrap.rkt"
         "lang/ident.rkt"
         "lang/source.rkt"
         "lang/complete.rkt"
         "lang/docs.rkt"
         "doc-job.rkt")

;;; lab-rebuild/builtin/complete.rkt —— 补全包（内置包）
;;;
;;; 全部通过扩展点接入：
;;;   · mode-type-register!  补全菜单是一个 mode
;;;   · keymap-define/添加   注册 complete 键表，并往 edit 表补 tab / C-n
;;;   · overlay-register!    画菜单 + 选中项 bluebox 文档
;;;   · hook-add!            打字后 refine、移动后取消、job-tick 装文档
;;;   · doc-job              异步查选中项文档（与 docs 包共用单例）
;;;
;;; 触发：显式 Tab / C-n，或打字（after-insert）自动弹。候选池一次会话只建一次。

(provide complete-init! complete-refine! complete-begin! complete-cancel!
         (struct-out complete))

;;; ================= 会话状态 =================

;; 补全菜单不占底部槽位、不动焦点，只在渲染时叠一个浮层。
;;   candidates  : (listof string)
;;   index       : 选中下标
;;   start       : 前缀起点（接受时替换 [start, 光标)）
;;   prev-focus  : 发起时的编辑 view
;;   mods        : 查候选 / 查文档的模块表
;;   pool        : 本次会话的完整候选池（复用）
;;   doc         : 选中项文档（bluebox）/ #f
;;   doc-pending : (cons 请求id 发起时的 document 值) / #f（版本闸门）
(struct complete (candidates index start prev-focus mods pool doc doc-pending) #:transparent)

(define complete-keys
  (keymap-define 'complete
   (key 'up)     '(complete-move -1)
   (key 'down)   '(complete-move 1)
   (key 'tab)    'complete-accept
   (key 'enter)  'complete-accept
   (key 'escape) 'complete-cancel))

;; 往编辑表补触发键（运行时 keymap 可变 → 立即生效）。
(keymap-add! (keymap-ensure! 'edit) (key 'tab) 'complete)
(keymap-add! (keymap-ensure! 'edit) (key 'n 'ctrl) 'complete)

;;; ================= 上下文 / 候选池 =================

(define (context-modules mods)
  (remove-duplicates (append mods '(racket racket/base)) equal?))

(define (edit-context a)
  (define ed (app-ed a))
  (define vid (app-focus a))
  (and vid (edit-panes-contains? (app-edit a) vid)
       (let* ([did (editor-view-document-id ed vid)]
              [path (path-table-path (app-paths a) did)]
              [base-dir (if path (let-values ([(d _n _m) (split-path path)]) d) (current-directory))]
              [text (editor-view-string ed vid)])
         (list vid text (source-requires text #:base-dir base-dir)))))

(define (build-pool text mods0)
  (define mods (context-modules mods0))
  (values mods (completion-pool #:modules mods #:locals (source-definitions text))))

(define (prefix-start p prefix)
  (point (point-line p) (max 0 (- (point-column p) (string-length prefix)))))

;; 为某个候选发起异步文档请求；pending = (cons id 发起时的 document 值)。
(define (pending-for a vid mods cand)
  (define ed (app-ed a))
  (define did (editor-view-document-id ed vid))
  (cons (doc-job-request! cand mods) (editor-document-handle ed did)))

;;; ================= 会话动作 =================

(define (complete-cancel! a)
  (when (complete? (app-mode a)) (app-mode-set! a #f)))

(define (complete-begin! a)
  (define ctx (edit-context a))
  (when ctx
    (define-values (vid text mods0) (apply values ctx))
    (define-values (mods pool) (build-pool text mods0))
    (define ed (app-ed a))
    (define p (editor-view-point ed vid))
    (define prefix (prefix-at text (point-line p) (point-column p)))
    (define cands (filter-pool pool prefix))
    (when (pair? cands)
      (app-mode-set! a (complete cands 0 (prefix-start p prefix) vid mods pool
                                 #f (pending-for a vid mods (car cands)))))))

(define (complete-refine! a)
  (define ctx (edit-context a))
  (cond
    [(not ctx) (complete-cancel! a)]
    [else
     (define-values (vid text mods0) (apply values ctx))
     (define ed (app-ed a))
     (define p (editor-view-point ed vid))
     (define prefix (prefix-at text (point-line p) (point-column p)))
     (define m (app-mode a))
     (define reuse? (and (complete? m) (eqv? (complete-prev-focus m) vid)))
     (define-values (mods pool)
       (if reuse?
           (values (complete-mods m) (complete-pool m))
           (build-pool text mods0)))
     (define cands (and (positive? (string-length prefix)) (filter-pool pool prefix)))
     (if (pair? cands)
         (app-mode-set! a (complete cands 0 (prefix-start p prefix) vid mods pool
                                    #f (pending-for a vid mods (car cands))))
         (complete-cancel! a))]))

(define (complete-move! a delta)
  (define m (app-mode a))
  (when (complete? m)
    (define cands (complete-candidates m))
    (define n (length cands))
    (when (positive? n)
      (define i (modulo (+ (complete-index m) delta) n))
      (app-mode-set! a (struct-copy complete m
                                    [index i]
                                    [doc #f]
                                    [doc-pending (pending-for a (complete-prev-focus m)
                                                              (complete-mods m)
                                                              (list-ref cands i))])))))

;; 接受：把 [start, 光标) 换成候选名。返回 (list changes vid) / #f。
(define (complete-accept! a)
  (define m (app-mode a))
  (and (complete? m)
       (let* ([cand (list-ref (complete-candidates m) (complete-index m))]
              [vid (complete-prev-focus m)]
              [ed (app-ed a)]
              [p (editor-view-point ed vid)]
              [start (complete-start m)])
         (app-mode-set! a #f)
         (editor-view-set-selections! ed vid (selections-one (selection start p)))
         (define-values (changes _ok?) (editor-view-insert! ed vid cand))
         (list changes vid))))

;; 异步文档回来：id 还是当前 mode 的 + 发起时的 document 还是当前的 → 装上。
(define (complete-job-tick! a)
  (doc-job-poll!)
  (define m (app-mode a))
  (when (complete? m)
    (define pend (complete-doc-pending m))
    (when pend
      (define id (car pend))
      (define ver (cdr pend))
      (define-values (ready? r) (doc-job-result id))
      (when ready?
        (define ed (app-ed a))
        (define vid (complete-prev-focus m))
        (when (and (edit-panes-contains? (app-edit a) vid)
                   (eq? ver (editor-document-handle ed (editor-view-document-id ed vid))))
          (app-mode-set! a (struct-copy complete m
                                        [doc (and r (apply doc r))]
                                        [doc-pending #f])))))))

;;; ================= 命令 =================

(define (cmd-complete e a) (complete-begin! a))
(define (cmd-complete-move e a delta) (complete-move! a delta))
(define (cmd-complete-cancel e a) (complete-cancel! a))
(define (cmd-complete-accept e a)
  (define r (complete-accept! a))
  (when r (hook-run! a 'after-edit (cadr r) (car r))))   ; 接受改文本 → 同步属性

(define-command complete        cmd-complete)
(define-command complete-move   cmd-complete-move)
(define-command complete-accept cmd-complete-accept)
(define-command complete-cancel cmd-complete-cancel)

;;; ================= mode-type =================
;;; 不独占（其余按键落回编辑表）；不占底部槽位；不动焦点。
(void
 (mode-type-register!
  (mode-type 'complete
             complete?
             (lambda (_) (list complete-keys))
             (lambda (_) 'state)
             (lambda (_) #f)
             #f #f)))

;;; ================= overlay =================

(define complete-face 'state)
(define complete-max-rows 10)
(define complete-doc-max-rows 18)

(define (complete-panes a)
  (define m (app-mode a))
  (if (complete? m) (complete-menu a m) '()))

(define (complete-menu a m)
  (define ed (app-ed a))
  (define vid (complete-prev-focus m))
  (define-values (arow acol) (anchor-screen-pos a vid (editor-view-point ed vid)))
  (cond
    [(not arow) '()]
    [else
     (define cands (complete-candidates m))
     (define idx (complete-index m))
     (define n (length cands))
     (define d (complete-doc m))
     (define avail-below (- (app-height a) (add1 arow)))
     (define avail-above arow)
     (define budget (max 1 (- (max avail-above avail-below) 2)))
     (define mrows (min complete-max-rows n budget))
     (define start (max 0 (min (- idx (quotient mrows 2)) (- n mrows))))
     (define shown (take (drop cands start) mrows))
     (define menu-cw (+ 2 (for/fold ([mx 0]) ([s (in-list shown)]) (max mx (string-length s)))))
     (define max-cw (max 10 (- (app-width a) 4)))
     (define inner (min max-cw (max menu-cw (if d 48 0))))
     (define doc-budget (max 0 (- budget mrows (if d 1 0))))
     (define doc-lines (and d (list->vector (wrap-lines (doc->text d) inner))))
     (define doc-rows (if doc-lines
                          (max 0 (min complete-doc-max-rows (vector-length doc-lines) doc-budget))
                          0))
     (define show-doc? (and d (positive? doc-rows)))
     (define menu-rows
       (for/list ([i (in-range mrows)])
         (define s (list-ref shown i))
         (define selected? (= (+ start i) idx))
         (cons (string-append " " s) (if selected? (cons 'cursor complete-face) complete-face))))
     (define doc-row-list
       (if show-doc?
           (for/list ([i (in-range doc-rows)]) (cons (vector-ref doc-lines i) complete-face))
           '()))
     (define menu-body (for/list ([c (in-list menu-rows)]) (box-line inner (car c) (cdr c))))
     (define doc-body (for/list ([c (in-list doc-row-list)]) (box-line inner (car c) (cdr c))))
     (define sep (list (list (box-hline inner box-lt box-rt))))
     (define h (+ mrows (if show-doc? (+ 1 doc-rows) 0) 2))
     (define above? (> h avail-below))
     (define body (if above?
                      (append doc-body (if show-doc? sep '()) menu-body)
                      (append menu-body (if show-doc? sep '()) doc-body)))
     (define top (if above? (max 0 (- arow h)) (add1 arow)))
     (define left (max 0 (min acol (max 0 (- (app-width a) (+ inner 2))))))
     (define rws (list->vector (append (list (list (box-hline inner box-tl box-tr)))
                                       body
                                       (list (list (box-hline inner box-bl box-br))))))
     (list (pane 'complete top left (screen (+ inner 2) h rws '() '()) 10))]))

(void (overlay-register! complete-panes))

;;; ================= 装配 =================

(define (complete-init! a)
  (hook-add! a 'after-insert (lambda (app vid changes) (complete-refine! app)))
  (hook-add! a 'after-nav (lambda (app . _) (complete-cancel! app)))
  (hook-add! a 'focus-changed (lambda (app vid) (complete-cancel! app)))
  (hook-add! a 'job-tick (lambda (app) (complete-job-tick! app)))
  a)
