#lang racket

(require racket/path
         "../../core/editor.rkt"
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
         "lang/docs.rkt"
         "doc-job.rkt")

;;; lab-rebuild/builtin/docs.rkt —— 文档查询包（内置包）
;;;
;;; 全部通过扩展点接入：
;;;   · mode-type-register!  文档浮窗是一个 mode（独占键表）
;;;   · keymap-define/添加   注册 docs 键表，并往 focus 表补 d
;;;   · overlay-register!    画浮窗
;;;   · app-job-add-source!  把异步 job 的结果源交给后端唤醒
;;;   · hook-add! job-tick   结果回来时装回 mode（版本闸门）
;;;
;;; 查文档在 place worker 里做（xref / bluebox 缓存在那边），主进程不阻塞。

(provide docs-init! app-show-docs! app-docs-close! app-docs-scroll!
         (struct-out docs))

(define (context-modules mods)
  (remove-duplicates (append mods '(racket racket/base)) equal?))

;;; ================= 会话状态 =================

;;   vid     : 发起时的编辑 view（拿光标屏幕位置做锚点）
;;   point   : 发起时光标位置
;;   lines   : (vectorof string) 已折行的内容
;;   offset  : 首行下标
;;   width   : 内容列宽（不含边框）
;;   rows    : 可见内容行数
;;   name    : 查的标识符（用于未找到提示）
;;   pending : (cons 请求id 发起时的 document 值) / #f（版本闸门）
(struct docs (vid point lines offset width rows name pending) #:transparent)

(define docs-keys
  (keymap-define 'docs
   (key 'enter)     'docs-close
   (key 'escape)    'docs-close
   (key 'up)        '(docs-scroll -1)
   (key 'down)      '(docs-scroll 1)
   (key 'pageup)    '(docs-scroll -10)
   (key 'pagedown)  '(docs-scroll 10)
   text-binding     'noop
   (key 'backspace) 'noop))

;; 往 C-p 焦点表补 d（运行时 keymap 可变）。
(keymap-add! (keymap-ensure! 'focus) (key 'd) 'show-docs)

;;; ================= 动作 =================

(define (app-show-docs! a)
  (define ed (app-ed a))
  (define vid (app-focus a))
  (when (and vid (edit-panes-contains? (app-edit a) vid))
    (define did (editor-view-document-id ed vid))
    (define path (path-table-path (app-paths a) did))
    (define base-dir (if path (let-values ([(d _n _m) (split-path path)]) d) (current-directory)))
    (define text (editor-view-string ed vid))
    (define p (editor-view-point ed vid))
    (define id (identifier-at text (point-line p) (point-column p)))
    (define mods (context-modules (source-requires text #:base-dir base-dir)))
    (define req-id (doc-job-request! (or id "") mods))
    (define ver (editor-document-handle ed did))
    (define width (max 20 (min 88 (- (app-width a) 6))))
    (define rows (max 1 (min 20 (- (app-height a) 4))))
    (define placeholder (cond [(not id) "（光标处没有标识符）"]
                              [else "查询文档…"]))
    (app-mode-set! a (docs vid p (list->vector (wrap-lines placeholder width)) 0 width rows
                           (or id "") (cons req-id ver)))))

(define (app-docs-close! a)
  (when (docs? (app-mode a)) (app-mode-set! a #f)))

(define (app-docs-scroll! a delta)
  (define m (app-mode a))
  (when (docs? m)
    (define n (vector-length (docs-lines m)))
    (define max-off (max 0 (- n (docs-rows m))))
    (app-mode-set! a (struct-copy docs m [offset (max 0 (min max-off (+ (docs-offset m) delta)))]))))

;; 异步结果回来：id 还是当前 mode 的 + 发起时的 document 还是当前的 → 装上。
(define (docs-job-tick! a)
  (doc-job-poll!)
  (define m (app-mode a))
  (when (docs? m)
    (define pend (docs-pending m))
    (when pend
      (define id (car pend))
      (define ver (cdr pend))
      (define-values (ready? r) (doc-job-result id))
      (when ready?
        (define ed (app-ed a))
        (define vid (docs-vid m))
        (when (and (edit-panes-contains? (app-edit a) vid)
                   (eq? ver (editor-document-handle ed (editor-view-document-id ed vid))))
          (define d (and r (apply doc r)))
          (define body (if d (doc->text d) (format "~a\n\n（未找到文档）" (docs-name m))))
          (app-mode-set! a (struct-copy docs m
                                        [lines (list->vector (wrap-lines body (docs-width m)))]
                                        [offset 0]
                                        [pending #f])))))))

;;; ================= 命令 =================

(define (cmd-show-docs e a) (app-show-docs! a))
(define (cmd-docs-close e a) (app-docs-close! a))
(define (cmd-docs-scroll e a delta) (app-docs-scroll! a delta))

(define-command show-docs   cmd-show-docs)
(define-command docs-close  cmd-docs-close)
(define-command docs-scroll cmd-docs-scroll)

;;; ================= mode-type =================
;;; 独占（其余按键吞掉，不编辑下面文档）；不占底部槽位；不动焦点。

(void
 (mode-type-register!
  (mode-type 'docs
             docs?
             (lambda (_) (list docs-keys))
             (lambda (_) 'state)
             (lambda (_) #f)
             #t #f)))

;;; ================= overlay =================

(define (docs-panes a)
  (define m (app-mode a))
  (cond
    [(not (docs? m)) '()]
    [else
     (define lines (docs-lines m))
     (define n (vector-length lines))
     (define cw (docs-width m))
     (define rows (max 1 (min (docs-rows m) n)))
     (define h (+ rows 2))
     (define-values (arow acol) (anchor-screen-pos a (docs-vid m) (docs-point m)))
     (cond
       [(not arow) '()]
       [else
        (define avail-below (- (app-height a) (add1 arow)))
        (define top (if (<= h avail-below) (add1 arow) (max 0 (- arow h))))
        (define left (max 0 (min acol (max 0 (- (app-width a) (+ cw 2))))))
        (define off (max 0 (min (docs-offset m) (max 0 (- n rows)))))
        (define content (for/list ([i (in-range rows)]) (cons (vector-ref lines (+ off i)) box-tface)))
        (list (frame-pane 'docs top left cw content 11))])]))

(void (overlay-register! docs-panes))

;;; ================= 装配 =================

(define (docs-init! a)
  (hook-add! a 'job-tick (lambda (app) (docs-job-tick! app)))
  (app-job-add-source! a doc-job-source)
  a)
