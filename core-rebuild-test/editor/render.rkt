#lang racket

;; 与 core/editor/render.rkt 对应的外部测试（单视图 / 布局合成 / 增量）。
(require rackunit
         "../../core-rebuild/editor.rkt"
         "../../core-rebuild/view/base/screen.rkt")

(define ed0 (editor-open "abc\ndef" 20 4 "d"))
(define-values (ed1 _) (editor-add-view ed0 0 20 4))              ; vid1

;; ---------- 单视图 ----------
(check-true (screen? (editor-view-render ed0 0)))
(check-equal? (map run-text (screen-row (editor-view-render ed0 0) 0)) '("abc"))

;; ---------- 多视图合成（rectangle 布局）----------
(define rectangles (list (rectangle 0 0 0 20 4 0) (rectangle 1 20 0 20 4 0)))
(define comp (editor-render-layout ed1 rectangles 0 40 4))
(check-equal? (map (lambda (r) (list (run-column r) (run-text r))) (screen-row comp 0))
              '((0 "abc") (20 "abc")))
(check-equal? (screen-cursors comp) (list (cursor 0 0 #t)))     ; 只 active 的光标透出
(check-equal? (screen-cursors (editor-render-layout ed1 rectangles 1 40 4))
              (list (cursor 0 20 #t)))
;; active 为 vid 列表 → 多个窗格的光标都透出（按 rectangle 顺序）
(check-equal? (screen-cursors (editor-render-layout ed1 rectangles '(0 1) 40 4))
              (list (cursor 0 0 #t) (cursor 0 20 #t)))

;; ---------- 增量 ----------
(define-values (n0 r0 s0) (editor-render-patch ed0 0 (editor-view-render ed0 0)))
(check-equal? r0 '())
(check-equal? s0 '())
;; 首帧（old = #f）→ 全量内容
(define-values (n1 r1 s1) (editor-render-layout-patch ed1 #f rectangles 0 40 4))
(check-equal? (screen->string n1) (screen->string comp))
(check-true (pair? r1))
(check-true (pair? s1))     ; 首帧光标进 selection 通道

(displayln "editor/render.rkt: all tests passed")
