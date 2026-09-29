#lang racket

;;; ============================================================================
;;; buffer.rkt —— 编辑格文档的输入
;;; ============================================================================
;;;
;;; 每个编辑格 pane 都是自洽的：这里把它的输入（键盘 / 鼠标 / 文本）翻译成 core 的
;;; 编辑与导航命令，作用在**它自己的视图**上。不碰树、不碰文档管理、不碰别的 pane。
;;;
;;; 定位用 pane-id：vid 从 app 的 pane 取（打开文件会换 vid，但 pane-id 不变）。
;;;
;;; 约定：
;;;   · 普通字符 / text → 插入；
;;;   · 方向键 → 移动，Shift+方向 → 扩选（extend? 由 core 处理）；
;;;   · 鼠标 press = 定位，move = 从**选区里的锚点**扩选（锚点无需额外状态），
;;;     滚轮 = 滚动；
;;;   · Ctrl-S 保存、Ctrl-W 关闭当前文档。

(require "../core/editor.rkt"
         "../core/text/base/point.rkt"
         "../core/text/base/selection.rkt"
         "app.rkt"
         "input.rkt")

(provide buffer-input buffer-pointer)

;;; ---------- 小工具 ----------

(define (plain? k)
  (and (not (key-ctrl? k)) (not (key-alt? k)) (not (key-meta? k))))

(define (ctrl? k c)
  (and (key-ctrl? k) (not (key-alt? k)) (not (key-meta? k)) (eqv? (key-name k) c)))

;; (无 ctrl/alt/meta) 判断，给"方向键"用 —— Shift 允许（表示扩选）。
(define (bare? k)
  (and (not (key-ctrl? k)) (not (key-alt? k)) (not (key-meta? k))))

;; 对编辑格自己的视图施加一个返回 editor 的函数，写回 app。
(define (buf-do a pid f)
  (define ed (app-editor a))
  (define vid (app-pane-vid a pid))
  (define ed* (call-with-values (lambda () (f ed vid)) (lambda (v . _) v)))
  (struct-copy app a [editor ed*]))

(define (buf-insert a pid s) (buf-do a pid (lambda (e v) (editor-view-insert e v s))))

;;; ---------- 键盘 ----------

(define (buf-key a pid k)
  (define n (key-name k))
  (define ext (key-shift? k))
  (cond
    ;; 文本输入
    [(and (plain? k) (char? n)) (buf-insert a pid (string n))]
    [(and (plain? k) (eq? n 'enter)) (buf-insert a pid "\n")]
    [(and (plain? k) (eq? n 'tab)) (buf-insert a pid "    ")]
    ;; 编辑
    [(and (plain? k) (eq? n 'backspace)) (buf-do a pid (lambda (e v) (editor-view-backspace e v 'backspace)))]
    [(and (plain? k) (memq n '(del delete))) (buf-do a pid (lambda (e v) (editor-view-delete e v 'delete)))]
    ;; 导航（Shift = 扩选）
    [(and (bare? k) (eq? n 'left)) (buf-do a pid (lambda (e v) (editor-view-left e v ext)))]
    [(and (bare? k) (eq? n 'right)) (buf-do a pid (lambda (e v) (editor-view-right e v ext)))]
    [(and (bare? k) (eq? n 'up)) (buf-do a pid (lambda (e v) (editor-view-up e v ext)))]
    [(and (bare? k) (eq? n 'down)) (buf-do a pid (lambda (e v) (editor-view-down e v ext)))]
    [(and (plain? k) (eq? n 'home)) (buf-do a pid (lambda (e v) (editor-view-home e v ext)))]
    [(and (plain? k) (eq? n 'end)) (buf-do a pid (lambda (e v) (editor-view-end e v ext)))]
    [(and (plain? k) (eq? n 'pageup)) (buf-do a pid (lambda (e v) (editor-view-scroll e v (- (editor-view-height e v)))))]
    [(and (plain? k) (eq? n 'pagedown)) (buf-do a pid (lambda (e v) (editor-view-scroll e v (editor-view-height e v))))]
    ;; Ctrl
    [(ctrl? k #\z) (buf-do a pid (lambda (e v) (editor-view-undo e v)))]
    [(ctrl? k #\y) (buf-do a pid (lambda (e v) (editor-view-redo e v)))]
    [(ctrl? k #\c) (buf-do a pid (lambda (e v) (editor-view-copy e v)))]
    [(ctrl? k #\v) (buf-do a pid (lambda (e v) (editor-view-paste e v)))]
    [(ctrl? k #\s) (app-save a pid)]
    [(ctrl? k #\w) (app-close a (editor-view-document-id (app-editor a) (app-pane-vid a pid)))]
    [else a]))

(define (buffer-input a pid in)
  (cond
    [(text? in) (buf-insert a pid (text-s in))]
    [(key? in) (buf-key a pid in)]
    [else a]))

;;; ---------- 鼠标 ----------

;; press 定位（光标）；move 从锚点扩选；scroll 滚动。
;; 锚点存在 core 的选区里（press 先设光标），所以不需要任何额外状态。
(define (buffer-pointer a pid in lr lc)
  (define ed (app-editor a))
  (define vid (app-pane-vid a pid))
  (case (pointer-action in)
    [(scroll) (buf-do a pid (lambda (e v) (editor-view-scroll e v (if (eq? (pointer-button in) 'up) -3 3))))]
    [else
     (define-values (line col) (editor-view-screen-pos->point ed vid lr lc))
     (cond
       [(not line) a]
       [(eq? (pointer-action in) 'press)
        (struct-copy app a [editor (editor-view-set-point ed vid (point line col))])]
       [(eq? (pointer-action in) 'move)
        (define prim (selections-primary (editor-view-selections ed vid)))
        (define anchor (selection-anchor prim))
        (struct-copy app a
          [editor (editor-view-set-selections ed vid
                    (selections-one (selection anchor (point line col))))])]
       [else a])]))
