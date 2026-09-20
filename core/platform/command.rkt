#lang racket

(require "../atom/point.rkt" "../atom/edit.rkt" "../atom/selection.rkt"
         "../doc/buffer.rkt" "../doc/batch.rkt"
         "../viewport/window.rkt" "../viewport/layout.rkt"
         "../unit/history.rkt"
         "state.rkt" "write.rkt" "neutral.rkt" "program.rkt" "reaction.rkt" rackunit)

;;; platform/command.rkt —— 用户面：leader + ensure + 账本
;;;
;;; 用户操作 = 内容变更 + 显示语义 leader + 账本，原语**按 vid 定位**（editor-view-*）：
;;;   · editor-view-edit      在指定 view 光标处编辑；leader 推进到插入后 + ensure；
;;;                           同 buffer 其余 free 映射 / follow 镜像；记一步。
;;;   · editor-view-undo/redo 按该 view 所属 buffer 的账本；leader 语义；撤销回到 pre-point。
;;;   · editor-view-*（导航） 更新该 view 的 window（ensure 可见），同 buffer follow 镜像它。
;;;
;;; 焦点只是**解析 vid 的糖**：editor-edit / editor-undo / editor-left … 一律落到上面的原语，
;;; 绝不反过来。程序操作（显式 buffer/位置、默认不动视图）在 program.rkt。

(provide
 ;; 用户面原语（按 vid；不读也不改 focus）
 editor-view-edit
 editor-view-undo
 editor-view-redo
 editor-view-left
 editor-view-right
 editor-view-up
 editor-view-down
 editor-view-home
 editor-view-end
 editor-view-goto
 editor-view-scroll
 ;; focus 糖
 editor-edit
 editor-undo
 editor-redo
 editor-left
 editor-right
 editor-up
 editor-down
 editor-home
 editor-end
 editor-goto
 editor-scroll)

;; 解析焦点 vid —— 用户面唯一读 focus 的地方。
(define (focused-vid ed) (view-id (editor-focused-view ed)))

;;; ---------- 编辑（指定 view，leader 语义） ----------

;; 两条 desc 的区间是否相交（半开）
(define (desc-overlap? d1 d2)
  (and (point<? (edit-desc-start d1) (edit-desc-end d2))
       (point<? (edit-desc-start d2) (edit-desc-end d1))))

;; 两个选区的包络（方向取正向）
(define (selection-hull a b)
  (define-values (as ae) (selection-range a))
  (define-values (bs be) (selection-range b))
  (selection (if (point<? bs as) bs as) (if (point<? ae be) be ae)))

;; 多选区：对每个选区算 desc；若两条 desc 重叠（backspace/delete 等会超出选区，
;; 相邻选区就会撞上），把冲突选区合并成包络再重算 op，直到 desc 两两不相交。
(define (coalesce-descs b0 sels op)
  (define pairs
    (filter values (for/list ([s (in-list sels)])
                     (define d (op b0 s))
                     (and d (cons s d)))))
  (let loop ([ps pairs])
    (cond
      [(null? ps) '()]
      [else
       (define p (car ps))
       (define conflicts (filter (lambda (q) (desc-overlap? (cdr p) (cdr q))) (cdr ps)))
       (cond
         [(null? conflicts) (cons (cdr p) (loop (cdr ps)))]
         [else
          (define group (cons p conflicts))
          (define hull (for/fold ([h (car (car group))]) ([g (in-list (cdr group))])
                         (selection-hull h (car g))))
          (define d (op b0 hull))
          (loop (if d
                    (cons (cons hull d) (remove* conflicts (cdr ps)))
                    (remove* conflicts (cdr ps))))])])))

(define (editor-view-edit ed vid op)
  (define v (editor-view-ref ed vid))
  (define bid (view-buffer-id v))
  (define w (view-window v))
  (define b0 (editor-buffer ed bid))
  (define pre (window-point w))
  ;; 对每个选区施加同一 op；空选区=插，非空=替换。重叠的 desc 先合并重算。
  (define descs (coalesce-descs b0 (window-selections w) op))
  (cond
    [(null? descs) (values ed #f)]
    [else
     (define-values (ed* ds ivs) (editor-apply-edit-batch ed bid descs #t))
     (cond
       [(null? ds) (values ed #f)]
       [else
        (define b* (editor-buffer ed* bid))
        (define ed** (editor-leader-view ed* vid b* ds))
        ;; 单条编辑走 edit-change（保留打字/退格的连续段合并）；多条走整批一步。
        (define ed***
          (if (= 1 (length ds))
              (let ([d (car ds)])
                (editor-record-history ed** bid
                                       (edit-change d (buffer-edit-desc-inverse b0 d) pre)))
              (editor-record-batch ed** bid ds (reverse ivs) pre)))
        (define-values (f l) (edits-span ds))
        (values ed*** (change-report f l ds))])]))

;;; ---------- 撤销 / 重做（指定 view 所属 buffer 的账本） ----------

(define (editor-view-undo ed vid)
  (define bid (view-buffer-id (editor-view-ref ed vid)))
  (define-values (st h*) (history-pop-undo (editor-history ed bid)))
  (cond
    [(not st) (values ed #f)]
    [else
     ;; undo-descs 是**依次施加**（每条坐标基于上一条之后），不能当同坐标批处理。
     (define ed* (for/fold ([e ed]) ([d (in-list (step-undo-descs st))])
                   (define-values (e1 d1) (editor-apply-edit e bid d #f))
                   (if d1 (editor-leader-view e1 vid (editor-buffer e1 bid) (list d1)) e1)))
     ;; 撤销后 leader 光标回到该步开始前，并 ensure
     (define w* (window-ensure-point
                 (window-set-point (view-window (editor-view-ref ed* vid)) (step-pre-point st))))
     (define ed** (editor-leader-window ed* vid w*))
     (define-values (f l) (edits-span (step-undo-descs st)))
     (values (editor-put-history ed** bid h*) (change-report f l (step-undo-descs st)))]))

(define (editor-view-redo ed vid)
  (define bid (view-buffer-id (editor-view-ref ed vid)))
  (define-values (st h*) (history-pop-redo (editor-history ed bid)))
  (cond
    [(not st) (values ed #f)]
    [else
     (define ed* (for/fold ([e ed]) ([d (in-list (step-replay-descs st))])
                   (define-values (e1 d1) (editor-apply-edit e bid d #f))
                   (if d1 (editor-leader-view e1 vid (editor-buffer e1 bid) (list d1)) e1)))
     (define-values (f l) (edits-span (step-replay-descs st)))
     (values (editor-put-history ed* bid h*) (change-report f l (step-replay-descs st)))]))

;;; ---------- 导航（指定 view；移动后 ensure + follow 镜像） ----------
;; editor-view-move 取 (window → window) 变换，**不对外**：它能看到并改写 window，
;; 会破坏「view.buffer-id ↔ window.buffer」不变量。对外只暴露具体动作。

(define (editor-view-move ed vid f)
  (define w* (window-ensure-point (f (view-window (editor-view-ref ed vid)))))
  (editor-leader-window ed vid w*))

(define (editor-view-left ed vid)  (editor-view-move ed vid window-left))
(define (editor-view-right ed vid) (editor-view-move ed vid window-right))
(define (editor-view-up ed vid)    (editor-view-move ed vid window-up))
(define (editor-view-down ed vid)  (editor-view-move ed vid window-down))
(define (editor-view-home ed vid)  (editor-view-move ed vid window-home))
(define (editor-view-end ed vid)   (editor-view-move ed vid window-end))
(define (editor-view-goto ed vid p)
  (editor-view-move ed vid (lambda (w) (window-set-point w p))))
(define (editor-view-scroll ed vid delta)
  (editor-leader-window ed vid
                        (window-scroll-visual (view-window (editor-view-ref ed vid)) delta)))

;;; ---------- focus 糖（用户面便捷；程序面请用上面的 editor-view-*） ----------

(define (editor-edit ed op)        (editor-view-edit ed (focused-vid ed) op))
(define (editor-undo ed)           (editor-view-undo ed (focused-vid ed)))
(define (editor-redo ed)           (editor-view-redo ed (focused-vid ed)))
(define (editor-left ed)           (editor-view-left ed (focused-vid ed)))
(define (editor-right ed)          (editor-view-right ed (focused-vid ed)))
(define (editor-up ed)             (editor-view-up ed (focused-vid ed)))
(define (editor-down ed)           (editor-view-down ed (focused-vid ed)))
(define (editor-home ed)           (editor-view-home ed (focused-vid ed)))
(define (editor-end ed)            (editor-view-end ed (focused-vid ed)))
(define (editor-goto ed p)         (editor-view-goto ed (focused-vid ed) p))
(define (editor-scroll ed delta)   (editor-view-scroll ed (focused-vid ed) delta))

;;; ---------- 测试 ----------

(module+ test
  ;; 单 buffer 编辑闭环 + 撤销/重做
  (define e0 (editor-open ""))
  (define-values (e1 r1) (editor-edit e0 (edit-insert-char #\a)))
  (define-values (e2 _u1) (editor-edit e1 (edit-insert-char #\b)))
  (define-values (e3 _u2) (editor-edit e2 (edit-insert-char #\c)))
  (check-equal? (editor-buffer->string e3 0) "abc")
  (check-equal? (change-report-first-line r1) 0)
  (check-equal? (editor-undo-depth e3 0) 1)          ; 打字连续段并成 1 步
  (define-values (u1 r-u3) (editor-undo e3))
  (check-equal? (editor-buffer->string u1 0) "")
  (check-equal? (editor-point u1) (point 0 0))
  ;; 撤销报告：施加顺序的 undo-descs
  (check-equal? (change-report-edits r-u3)
                (list (edit-desc (point 0 2) (point 0 3) "")
                      (edit-desc (point 0 1) (point 0 2) "")
                      (edit-desc (point 0 0) (point 0 1) "")))
  (define-values (r1b r-u4) (editor-redo u1))
  (check-equal? (editor-buffer->string r1b 0) "abc")
  (check-equal? (change-report-edits r-u4)
                (list (edit-desc (point 0 0) (point 0 0) "a")
                      (edit-desc (point 0 1) (point 0 1) "b")
                      (edit-desc (point 0 2) (point 0 2) "c")))

  ;; 多 buffer：各自独立文本 / 账本
  (define ed (editor-open "AAA"))
  (define-values (ed2 bid1) (editor-open-buffer ed "b.txt" "BBB" #:focus? #t))
  (check-equal? (editor-focused-buffer-id ed2) bid1)
  (define-values (ed3 _u5) (editor-edit ed2 (edit-insert "x")))
  (check-equal? (editor-buffer->string ed3 bid1) "xBBB")
  (check-equal? (editor-buffer->string ed3 0) "AAA")
  (check-true (editor-can-undo? ed3 bid1))
  (check-false (editor-can-undo? ed3 0))

  ;; 多视图同 buffer：free 映射、follow 镜像
  (define m0 (editor-open "l0\nl1\nl2\nl3\nl4\nl5\nl6"))
  (define-values (m1 v0) (editor-add-view m0 0 3 10))         ; 默认不抢焦点：仍停在 view 0
  (define m2 (editor-focus-view (editor-view-set-sync m1 v0 'follow) 0))
  (define m3 (editor-goto m2 (point 0 0)))
  (define-values (m4 _u6) (editor-edit m3 (edit-insert "XY")))
  (check-equal? (editor-buffer->string m4 0) "XYl0\nl1\nl2\nl3\nl4\nl5\nl6")
  (check-equal? (editor-point m4) (point 0 2))
  (check-equal? (editor-view-point m4 v0) (point 0 2))
  (check-eq? (editor-buffer m4 0) (window-buffer (view-window (editor-view-ref m4 v0))))

  ;; 同步契约：follow 镜像 leader 视口；free 钉住；别的 buffer 不动
  (define g0 (editor-open (string-join (map number->string (range 30)) "\n") 5 20))
  (define-values (g1 vfree) (editor-add-view g0 0 5 20 #:focus? #f))
  (define-values (g2 vfollow) (editor-add-view g1 0 5 20 #:sync 'follow #:focus? #f))
  (define-values (g3 other) (editor-open-buffer g2 "other" "OTHER"))
  (define g4 (editor-focus-view g3 0))
  (define g5 (editor-goto g4 (point 20 0)))
  (check-equal? (editor-top-line g5) 16)
  (check-equal? (editor-view-top-line g5 vfree) 0)
  (check-equal? (editor-view-top-line g5 vfollow) (editor-top-line g5))
  (define-values (g6 _u9) (editor-edit g5 (edit-insert-char #\X)))
  (check-equal? (editor-buffer->string g6 other) "OTHER")
  (check-equal? (editor-view-top-line g6 vfollow) (editor-view-top-line g6 0))
  (check-eq? (editor-buffer g6 0) (window-buffer (view-window (editor-view-ref g6 vfollow))))

  ;; 显式 vid 的用户语义：不抢焦点，只作用目标 view
  (define p0 (editor-open "l0\nl1\nl2\nl3\nl4\nl5\nl6"))
  (define-values (p1 pv) (editor-add-view p0 0 3 10 #:focus? #f))
  (define p2 (editor-view-goto p1 pv (point 3 0)))
  (check-equal? (editor-view-point p2 pv) (point 3 0))
  (check-equal? (editor-point p2) (point 0 0))              ; 焦点 view 光标不动
  (define-values (p3 _r) (editor-view-edit p2 pv (edit-insert "X")))
  (check-equal? (editor-buffer->string p3 0) "l0\nl1\nl2\nXl3\nl4\nl5\nl6")
  (check-equal? (editor-point p3) (point 0 0))
  (check-true (editor-can-undo? p3 0))
  (define-values (p4 _r2) (editor-view-undo p3 pv))
  (check-equal? (editor-buffer->string p4 0) "l0\nl1\nl2\nl3\nl4\nl5\nl6")
  (define p5 (editor-view-scroll p4 pv 2))
  (check-equal? (editor-view-top-line p5 0) 0)              ; 焦点 view 视口不动

  ;; 多光标：一组选区，一次替换全部；整批记一步
  (define mc0 (editor-open "foo bar foo"))
  (define mc1 (editor-set-selections mc0 (list (selection (point 0 0) (point 0 3))
                                               (selection (point 0 8) (point 0 11)))))
  (check-equal? (length (editor-selections mc1)) 2)
  (define-values (mc2 _r-mc) (editor-edit mc1 (edit-insert "XX")))
  (check-equal? (editor-buffer->string mc2 0) "XX bar XX")
  (check-equal? (editor-undo-depth mc2 0) 1)                 ; 整批一步
  (check-equal? (length (editor-selections mc2)) 2)          ; 两选区各自映射
  (define-values (mc3 _u-mc) (editor-undo mc2))
  (check-equal? (editor-buffer->string mc3 0) "foo bar foo")

  ;; 多光标退格：每个光标删各自前一个字符（选区为空时）
  (define mc4 (editor-set-selections (editor-open "abc")
                                     (list (selection (point 0 1) (point 0 1))
                                           (selection (point 0 3) (point 0 3)))))
  (define-values (mc5 _r5) (editor-edit mc4 (edit-backspace)))
  (check-equal? (editor-buffer->string mc5 0) "b")

  ;; 跨行选区 + 边界光标：desc 重叠 → 合并重算，不崩（回归）
  (define oc (editor-set-selections (editor-open "abc\ndef\nghi")
                                    (list (selection (point 0 0) (point 1 0)) (caret (point 1 0)))))
  (check-equal? (length (editor-selections oc)) 2)
  (define-values (oc1 _oc) (editor-edit oc (edit-backspace)))
  (check-equal? (editor-buffer->string oc1 0) "def\nghi")
  ;; 前向删除同边界情形
  (define od (editor-set-selections (editor-open "abc\ndef")
                                    (list (caret (point 0 0)) (selection (point 0 0) (point 0 2)))))
  (define-values (od1 _od) (editor-edit od (edit-delete)))
  (check-equal? (editor-buffer->string od1 0) "c\ndef")

  (displayln "command.rkt: all tests passed"))
