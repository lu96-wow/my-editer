#lang racket

;;; buffer.rkt —— 编辑格文档的输入
;;;
;;; 每个文档自洽：这里只认「焦点在某个编辑视图上」时的输入，把它翻译成 core 的
;;; 编辑/导航命令，作用在该视图上。不碰树、不碰文档管理、不碰别的 state。

(require "../core/editor.rkt"
         "../core/text/base/point.rkt"
         "app.rkt"
         "input.rkt")

(provide buffer-input)

(define (plain? k)
  (and (not (key-ctrl? k)) (not (key-alt? k)) (not (key-meta? k))))

(define (ctrl? k c)
  (and (key-ctrl? k) (not (key-alt? k)) (not (key-meta? k))
       (eqv? (key-name k) c)))

;; 对编辑格视图施加一个返回 editor 的函数。
(define (buf-do a f)
  (define ed (app-editor a))
  (define vid (app-editor-vid a))
  (define ed* (call-with-values (lambda () (f ed vid)) (lambda (v . _) v)))
  (struct-copy app a [editor ed*]))

(define (buf-insert a s) (buf-do a (lambda (e v) (editor-view-insert e v s))))

(define (buf-key a k)
  (define n (key-name k))
  (define ext (key-shift? k))
  (cond
    ;; 文本
    [(and (plain? k) (char? n)) (buf-insert a (string n))]
    [(and (plain? k) (eq? n 'enter)) (buf-insert a "\n")]
    [(and (plain? k) (eq? n 'tab)) (buf-insert a "    ")]
    ;; 编辑
    [(and (plain? k) (eq? n 'backspace)) (buf-do a (lambda (e v) (editor-view-backspace e v 'backspace)))]
    [(and (plain? k) (memq n '(del delete))) (buf-do a (lambda (e v) (editor-view-delete e v 'delete)))]
    ;; 导航（Shift = 扩选）
    [(and (not (key-ctrl? k)) (not (key-alt? k)) (not (key-meta? k)) (eq? n 'left)) (buf-do a (lambda (e v) (editor-view-left e v ext)))]
    [(and (not (key-ctrl? k)) (not (key-alt? k)) (not (key-meta? k)) (eq? n 'right)) (buf-do a (lambda (e v) (editor-view-right e v ext)))]
    [(and (not (key-ctrl? k)) (not (key-alt? k)) (not (key-meta? k)) (eq? n 'up)) (buf-do a (lambda (e v) (editor-view-up e v ext)))]
    [(and (not (key-ctrl? k)) (not (key-alt? k)) (not (key-meta? k)) (eq? n 'down)) (buf-do a (lambda (e v) (editor-view-down e v ext)))]
    [(and (plain? k) (eq? n 'home)) (buf-do a (lambda (e v) (editor-view-home e v ext)))]
    [(and (plain? k) (eq? n 'end)) (buf-do a (lambda (e v) (editor-view-end e v ext)))]
    [(and (plain? k) (eq? n 'pageup)) (buf-do a (lambda (e v) (editor-view-scroll e v (- (editor-view-height e v)))))]
    [(and (plain? k) (eq? n 'pagedown)) (buf-do a (lambda (e v) (editor-view-scroll e v (editor-view-height e v))))]
    ;; Ctrl
    [(ctrl? k #\z) (buf-do a (lambda (e v) (editor-view-undo e v)))]
    [(ctrl? k #\y) (buf-do a (lambda (e v) (editor-view-redo e v)))]
    [(ctrl? k #\c) (buf-do a (lambda (e v) (editor-view-copy e v)))]
    [(ctrl? k #\v) (buf-do a (lambda (e v) (editor-view-paste e v)))]
    [(ctrl? k #\s) (app-save a)]
    [(ctrl? k #\w) (app-close a (editor-view-document-id (app-editor a) (app-editor-vid a)))]
    [else a]))

(define (buffer-input a in)
  (cond
    [(text? in) (buf-insert a (text-s in))]
    [(key? in) (buf-key a in)]
    [else a]))
