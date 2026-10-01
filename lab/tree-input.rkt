#lang racket

;;; ============================================================================
;;; tree-input.rkt —— 文件树的输入分发
;;; ============================================================================
;;;
;;; 把按键 / 鼠标翻译成「模型变换 + effects」。不碰投影（那是 project）、不碰
;;; 磁盘（那是 prompt / files）：需要文件动作时交给 tree-prompt。
;;;
;;;   handle-input    ctx state input        → (values state effects)
;;;   handle-pointer  ctx state input 行 列  → (values state effects)

(require "tree-model.rkt"
         "tree-project.rkt"
         "tree-prompt.rkt"
         "input.rkt"
         "state.rkt"
         "fs.rkt"
         "../core/editor.rkt"
         "../core/text/base/point.rkt")

(provide handle-input handle-pointer)

;;; ---------- 光标处 ----------

(define (tree-cursor-line ctx)
  (editor-view-point-line (ctx-editor ctx) (ctx-vid ctx)))

(define (tree-cur-entry ctx st)
  (tree-line-entry st (tree-cursor-line ctx)))

(define (tree-target ctx st)
  (tree-target-dir st (tree-cursor-line ctx)))

(define (core-do ctx st f) (f (ctx-editor ctx) (ctx-vid ctx)) (values st '()))

;;; ---------- 文件模式动作 ----------

(define (tree-activate ctx st)
  (define e (tree-cur-entry ctx st))
  (cond
    [(not e) (values st '())]
    [(entry-dir? e) (values (tree-toggle! st e) '())]
    [else (values st (list (list 'open (entry-path e))))]))

(define (tree-delete ctx st)
  (define e (tree-cur-entry ctx st))
  (cond
    [(not e) (values st '())]
    [(equal? (entry-path e) (entry-path (tree-root st))) (values st '())]
    [else
     (values (prompt-begin st 'delete
                           (format "删除~a ~a？(y/n) "
                                   (if (entry-dir? e) "目录" "文件") (entry-name e))
                           (entry-path e))
             '())]))

;;; ---------- 视图模式动作 ----------

;; 回车：显示选中的视图到编辑格（已在别的窗格就聚焦那个窗格）并聚焦。
(define (tree-view-activate ctx st)
  (define vid (tree-open-view-vid (ctx-open-views ctx) (tree-cursor-line ctx)))
  (if vid (values st (list (list 'focus-view vid))) (values st '())))

;; d：关掉选中的视图（最后一个视图连文档一起关）。
(define (tree-view-close ctx st)
  (define vid (tree-open-view-vid (ctx-open-views ctx) (tree-cursor-line ctx)))
  (if vid (values st (list (list 'close-view vid))) (values st '())))

;; n：给选中的视图所属文档再开一个新视图（克隆光标），显示到编辑格并聚焦。
(define (tree-view-new ctx st)
  (define vid (tree-open-view-vid (ctx-open-views ctx) (tree-cursor-line ctx)))
  (cond
    [(not vid) (values st '())]
    [else
     (define ed (ctx-editor ctx))
     (define did (editor-view-document-id ed vid))
     (define point (editor-view-point ed vid))
     (values st (list (list 'new-view did point)))]))

;;; ---------- 模式 ----------

(define (tree-toggle-mode st)
  (struct-copy tree st [mode (if (eq? (tree-mode st) 'files) 'views 'files)] [prompt #f] [goto #f]))

(define (plain? k) (and (not (key-ctrl? k)) (not (key-alt? k)) (not (key-meta? k))))

;; 文件模式：导航 / 回车开合 / n 新建文件 / m 新建目录 / d 删除 / v 切视图表。
(define (tree-file-key ctx st k)
  (define n (key-name k))
  (cond
    [(and (plain? k) (eq? n 'up)) (core-do ctx st (lambda (e v) (editor-view-up! e v)))]
    [(and (plain? k) (eq? n 'down)) (core-do ctx st (lambda (e v) (editor-view-down! e v)))]
    [(and (plain? k) (eq? n 'left)) (core-do ctx st (lambda (e v) (editor-view-left! e v)))]
    [(and (plain? k) (eq? n 'right)) (core-do ctx st (lambda (e v) (editor-view-right! e v)))]
    [(and (plain? k) (eq? n 'enter)) (tree-activate ctx st)]
    [(and (plain? k) (char? n) (char=? (char-downcase n) #\v)) (values (tree-toggle-mode st) '())]
    [(and (plain? k) (char? n) (char=? n #\n))
     (values (prompt-begin st 'file "新建文件: " (tree-target ctx st)) '())]
    [(and (plain? k) (char? n) (char=? n #\m))
     (values (prompt-begin st 'dir "新建目录: " (tree-target ctx st)) '())]
    [(and (plain? k) (char? n) (char=? n #\d)) (tree-delete ctx st)]
    [else (values st '())]))

;; 视图模式：导航 / 回车切换视图 / n 新建视图 / d 关视图 / v（或 Esc）回文件。
(define (tree-view-key ctx st k)
  (define n (key-name k))
  (cond
    [(and (plain? k) (eq? n 'up)) (core-do ctx st (lambda (e v) (editor-view-up! e v)))]
    [(and (plain? k) (eq? n 'down)) (core-do ctx st (lambda (e v) (editor-view-down! e v)))]
    [(and (plain? k) (eq? n 'left)) (core-do ctx st (lambda (e v) (editor-view-left! e v)))]
    [(and (plain? k) (eq? n 'right)) (core-do ctx st (lambda (e v) (editor-view-right! e v)))]
    [(and (plain? k) (eq? n 'enter)) (tree-view-activate ctx st)]
    [(and (plain? k) (eq? n 'escape)) (values (tree-toggle-mode st) '())]
    [(and (plain? k) (char? n) (char=? (char-downcase n) #\v)) (values (tree-toggle-mode st) '())]
    [(and (plain? k) (char? n) (char=? (char-downcase n) #\n)) (tree-view-new ctx st)]
    [(and (plain? k) (char? n) (char=? n #\d)) (tree-view-close ctx st)]
    [else (values st '())]))

(define (tree-key ctx st k)
  (case (tree-mode st)
    [(views) (tree-view-key ctx st k)]
    [else (tree-file-key ctx st k)]))

;;; ---------- 对外 ----------

(define (handle-input ctx st in)
  (cond
    [(prompt-active? st)
     (cond
       [(text? in) (values (prompt-type st (text-s in)) '())]
       [(key? in) (prompt-key st (ctx-opened ctx) in)]
       [else (values st '())])]
    [(key? in) (tree-key ctx st in)]
    [else (values st '())]))

(define (handle-pointer ctx st in lr lc)
  (case (pointer-action in)
    [(scroll) (core-do ctx st (lambda (e v) (editor-view-scroll! e v (if (eq? (pointer-button in) 'up) -3 3))))]
    [else
     (define-values (line _col) (editor-view-screen-pos->point (ctx-editor ctx) (ctx-vid ctx) lr lc))
     (cond
       [(not line) (values st '())]
       [(memq (pointer-action in) '(press move))
        (editor-view-set-point! (ctx-editor ctx) (ctx-vid ctx) (point line 0))
        (values st '())]
       [else (values st '())])]))
