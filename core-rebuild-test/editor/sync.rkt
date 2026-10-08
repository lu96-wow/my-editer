#lang racket

;; 视口锚点测试（core/editor/query.rkt + command.rkt）：
;;     editor-view-anchor        / editor-view-set-anchor!        （显示坐标）
;;     editor-view-anchor-point  / editor-view-set-anchor-point!  （字符坐标）
;;
;; 覆盖：取/放、跨 mode、越界夹取、宽字符换算、不改选区；
;; 以及组装一个视口同步（取 leader 锚 → 映射 → 落 follower）。

(require rackunit
         "../../core-rebuild/editor.rkt"
         "../../core-rebuild/text/base/point.rkt"
         "../../core-rebuild/text/base/selection.rkt")

;;; ---------- 焦点 shim ----------
(define focus (make-parameter 0))
(define (focus-of ed)
  (define f (focus))
  (if (memv f (editor-view-id-list ed)) f 0))

(define (eo text w h [name "*scratch*"] #:mode [m 'clip] #:line-numbers? [ln #f])
  (focus 0)
  (editor-open text w h name #:mode m #:line-numbers? ln))

(define (add-view ed did w h #:mode [m 'clip] #:line-numbers? [ln #f])
  (let-values ([(e _) (editor-add-view ed did w h #:mode m #:line-numbers? ln)]) e))

(define (scroll ed d) (editor-view-scroll! ed (focus-of ed) d) ed)
(define (goto ed p) (editor-view-set-point! ed (focus-of ed) p) ed)
(define (set-mode ed m) (editor-view-set-mode! ed (focus-of ed) m) ed)

(define (vtl ed vid) (editor-view-top-line ed vid))
(define (vlc ed vid) (editor-view-left-column ed vid))
(define (vts ed vid) (editor-view-top-segment ed vid))
(define (anchor ed vid) (call-with-values (lambda () (editor-view-anchor ed vid)) list))

(define many (string-join (for/list ([i (in-range 40)]) (format "line ~a" i)) "\n"))

;;; ================= ① 锚点 =================

;; 取 / 放：clip 锚 = (top-line, left-column)
(define p0 (eo many 20 5))
(check-equal? (anchor p0 0) '(0 0))
(editor-view-set-anchor! p0 0 6 0)
(check-equal? (vtl p0 0) 6)
(editor-view-set-anchor-point! p0 0 (point 12 0))
(check-equal? (anchor p0 0) '(12 0))
(check-equal? (editor-view-anchor-point p0 0) (point 12 0))
;; 行越界先夹
(editor-view-set-anchor! p0 0 999 0)
(check-equal? (vtl p0 0) 39)

;; 字符坐标越界也夹回合法域；末行 "line 39" 宽 7
(editor-view-set-anchor-point! p0 0 (point 999 999))
(check-equal? (anchor p0 0) '(39 7))
(editor-view-set-anchor-point! p0 0 (point -1 0))
(check-equal? (anchor p0 0) '(0 0))

;; 落锚不改选区、不改其它 view
(define p1 (add-view p0 0 20 5))
(editor-view-set-point! p1 0 (point 3 0))
(define sels-before (editor-view-selections p1 0))
(editor-view-set-anchor! p1 0 10 0)
(check-equal? (editor-view-selections p1 0) sels-before)
(check-equal? (vtl p1 1) 0)                                     ; 跟随者没有被动过

;; 同一个锚跨 mode：clip 落 left-column；wrap 落段
(define pm (eo "abcdefghij\nsecond line here" 6 3))
(editor-view-set-anchor! pm 0 0 7)
(check-equal? (vlc pm 0) 7)
(void (set-mode pm 'wrap))
(editor-view-set-anchor! pm 0 0 7)
(check-equal? (vts pm 0) 1)                                     ; 列 7 → 段 1

;; 字符坐标：按显示宽折算
(define pc (eo "中文中文中\n第二行" 10 3))
(editor-view-set-anchor-point! pc 0 (point 0 3))
(check-equal? (editor-view-anchor-point pc 0) (point 0 3))      ; 字符 3
(check-equal? (anchor pc 0) '(0 6))                             ; 显示列 = 3×2
(editor-view-set-anchor! pc 0 0 4)                              ; 显示列 4 → 字符 2
(check-equal? (editor-view-anchor-point pc 0) (point 0 2))

;; 两个 view 看同一文档：滚一个，另一个不动
(define q0 (eo many 20 5))
(define q1 (add-view q0 0 20 5))
(void (scroll q1 8))
(check-equal? (vtl q1 0) 8)
(check-equal? (vtl q1 1) 0)

;;; ================= ② 组装一个视口同步 =================
;; 取 leader 锚 → pos-map 映射 → 落 follower。

(define (sync-view! ed leader follower pos-map)
  (define p (editor-view-anchor-point ed leader))
  (define p* (pos-map p))
  (when p* (editor-view-set-anchor-point! ed follower p*)))

;; 同文档：恒等映射
(define r0 (eo many 20 5))
(define r1 (add-view r0 0 20 5))
(editor-view-set-anchor! r1 0 12 0)
(sync-view! r1 0 1 identity)
(check-equal? (vtl r1 1) 12)

;; 跨文档：对应关系用字符坐标表示，显示列按显示宽折算
;;   源文档 (doc0)                   目标文档 (doc1)
;;   "aaaaaaaaaa"  ← 字符 6 → 字符 3 →  "中文中文中"
(define-values (s1 s1-did) (editor-add-document r1 "中文中文中\n第二行"))
(let-values ([(s2 s1-vid) (editor-add-view s1 s1-did 10 3)])
  ;; 源视图锚到字符列 6
  (editor-view-set-anchor-point! s2 0 (point 0 6))
  ;; 示例映射：字符列 / 2
  (define (en->zh p) (point (point-line p) (quotient (point-column p) 2)))
  (sync-view! s2 0 s1-vid en->zh)
  ;; follower（doc1）拿到 point (0,3)；显示列折成 6
  (check-equal? (editor-view-anchor-point s2 s1-vid) (point 0 3))
  (check-equal? (anchor s2 s1-vid) '(0 6))
  ;; 映射返回 #f → 不改 follower
  (sync-view! s2 0 s1-vid (lambda (_p) #f))
  (check-equal? (vtl s2 s1-vid) 0))

;; 同步不改 follower 选区
(define u0 (eo many 20 5))
(define u1 (add-view u0 0 20 5))
(editor-view-set-point! u1 1 (point 2 1))
(editor-view-set-anchor! u1 0 9 0)
(define u1-sels (editor-view-selections u1 1))
(sync-view! u1 0 1 identity)
(check-equal? (editor-view-selections u1 1) u1-sels)

(displayln "editor/sync.rkt: all tests passed")
