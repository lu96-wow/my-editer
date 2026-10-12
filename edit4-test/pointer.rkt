#lang racket

;;; edit4-test/pointer.rkt —— 鼠标点击定位（屏幕坐标 → 文档点）

(require rackunit
         racket/list
         "../edit4/layout.rkt"
         "../edit4/core.rkt"
         "../edit4/content/model.rkt"
         "../edit4/content/adapter.rkt"
         "../edit4/content/commands.rkt"
         "../edit4/content/scopes.rkt")

(define SZ (cons 80 24))
(define reg (command-registry-merge base-commands content-commands))
(define km (compose-keymaps (list content-keymap base-keymap)))
(define (mk-ctx w ev)
  (define area (rect 0 0 (car SZ) (cdr SZ)))
  (define tiled (layout (world-layout w) area))
  (define frects (place-floats (geometry-rects tiled) (world-floats w) area))
  (ctx ev SZ (frame tiled frects (car SZ) (cdr SZ))))
(define (run w ev)
  (call-with-values (lambda () (dispatch reg content-scopes km (mk-ctx w ev) w)) list))
(define (W st) (car st))

;;; ---------- 单窗：点 (col=2,row=1) → 文档点 (1 . 2) ----------

(define c0 (content-blank))
(define-values (c1 did vid) (content-add-doc! c0 "abc\ndefg\nhi" 40 10 "t" #f))
(define w0 (make-world #:layout (leaf 0 (cons 2 2)) #:focus 0 #:content (content-bind c1 0 vid)))
(define ed (content-ed (world-content w0)))
(define s1 (run w0 (cursor-event 'press 'left 2 1)))
(check-equal? (world-focus (W s1)) 0)
(check-equal? (view-line ed vid) 1)
(check-equal? (view-col ed vid) 2)

;; 点第二行末尾 → 列被夹到该行长度
(define s2 (run w0 (cursor-event 'press 'left 79 2)))
(check-equal? (view-line ed vid) 2)
(check-equal? (view-col ed vid) 2)              ; "hi" 只有 2 列

;;; ---------- 两窗：点左窗 → 焦点切换 + 光标 ----------

(define lay2 (split 'h 1 (list (child (size 2 #t) (leaf 0 (cons 2 2)))
                               (child (size 2 #t) (leaf 1 (cons 2 2))))))
(define w2 (make-world #:layout lay2 #:focus 1 #:content (content-bind c1 0 vid)))
(define s3 (run w2 (cursor-event 'press 'left 3 0)))
(check-equal? (world-focus (W s3)) 0)           ; 左窗 rect x=0..39
(check-equal? (view-line ed vid) 0)
(check-equal? (view-col ed vid) 3)

;;; ---------- 缝上按下 → 仍是拖拽（内容扩展不改 base 行为） ----------

(define s4 (run w2 (cursor-event 'press 'left 40 5)))   ; x=40 是缝
(check-true (dragging? (world-drag (W s4))))
(check-equal? (view-line ed vid) 0)             ; 光标未被移动
(check-equal? (view-col ed vid) 3)

;;; ---------- 空窗（无 vid）点击 → 只设焦点，不动光标 ----------

(define w3 (make-world #:layout lay2 #:focus 0 #:content (content-bind c1 0 vid)))
(define s5 (run w3 (cursor-event 'press 'left 60 2)))   ; 右窗无文档
(check-equal? (world-focus (W s5)) 1)
(check-equal? (view-line ed vid) 0)             ; 文档光标未变
(check-equal? (view-col ed vid) 3)

(displayln "edit4/pointer.rkt: all tests passed")
