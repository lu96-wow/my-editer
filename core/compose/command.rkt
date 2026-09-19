#lang racket

(require "../text/point.rkt" "../text/content.rkt" "../text/buffer.rkt" "../text/edit.rkt"
         "../view/window.rkt" "../view/view.rkt"
         "../tool/history.rkt"
         "editor.rkt" "reaction.rkt" rackunit)

;;; core/compose/command.rkt —— 用户面：焦点 + leader + ensure + 账本
;;;
;;; 用户操作 = 内容变更 + 显示语义 leader + 账本，全部落在**焦点 view** 上：
;;;   · editor-edit      在焦点 view 光标处编辑；leader 推进到插入后 + ensure；
;;;                      同 buffer 其余 free 映射 / follow 镜像；记一步。
;;;   · editor-undo/redo 按焦点 view 所属 buffer 的账本；leader 语义；撤销回到 pre-point。
;;;   · 导航             更新焦点 view 的 window（ensure 可见），同 buffer follow 镜像它。
;;;
;;; 程序操作（显式 buffer/位置、默认不动视图）在 program.rkt。

(provide
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

;;; ---------- 编辑（焦点 view，leader 语义） ----------

(define (editor-edit ed op)
  (define fv (editor-focused-view ed))
  (define vid (view-id fv))
  (define bid (view-buffer-id fv))
  (define b0 (editor-buffer ed bid))
  (define p0 (window-point (view-window fv)))
  (define d (op b0 p0))
  (cond
    [(not d) (values ed #f)]
    [else
     (define-values (ed* d*) (editor-apply-desc ed bid d #t))
     (cond
       [(not d*) (values ed #f)]
       [else
        (define b* (editor-buffer ed* bid))
        (define ed** (editor-leader-view ed* vid b* d*))
        (define ch (edit-change d* (buffer-edit-desc-inverse b0 d*) p0))
        (define-values (f l) (edits-span (list d*)))
        (values (editor-record-history ed** bid ch) (change-report f l))])]))

;;; ---------- 撤销 / 重做 ----------

(define (editor-undo ed)
  (define fv (editor-focused-view ed))
  (define vid (view-id fv))
  (define bid (view-buffer-id fv))
  (define-values (st h*) (history-pop-undo (editor-history ed bid)))
  (cond
    [(not st) (values ed #f)]
    [else
     (define ed* (for/fold ([e ed]) ([d (in-list (step-undo-descs st))])
                   (define-values (e1 d1) (editor-apply-desc e bid d #f))
                   (if d1 (editor-leader-view e1 vid (editor-buffer e1 bid) d1) e1)))
     ;; 撤销后 leader 光标回到该步开始前，并 ensure
     (define w* (window-ensure-point
                 (window-set-point (view-window (editor-view-ref ed* vid)) (step-pre-point st))))
     (define ed** (editor-leader-window ed* vid w*))
     (define-values (f l) (edits-span (step-undo-descs st)))
     (values (editor-put-history ed** bid h*) (change-report f l))]))

(define (editor-redo ed)
  (define fv (editor-focused-view ed))
  (define vid (view-id fv))
  (define bid (view-buffer-id fv))
  (define-values (st h*) (history-pop-redo (editor-history ed bid)))
  (cond
    [(not st) (values ed #f)]
    [else
     (define ed* (for/fold ([e ed]) ([d (in-list (step-replay-descs st))])
                   (define-values (e1 d1) (editor-apply-desc e bid d #f))
                   (if d1 (editor-leader-view e1 vid (editor-buffer e1 bid) d1) e1)))
     (define-values (f l) (edits-span (step-replay-descs st)))
     (values (editor-put-history ed* bid h*) (change-report f l))]))

;;; ---------- 导航（焦点 view；移动后 ensure + follow 镜像） ----------

(define (editor-move ed f)
  (define fv (editor-focused-view ed))
  (define vid (view-id fv))
  (define w* (window-ensure-point (f (view-window fv))))
  (editor-leader-window ed vid w*))

(define (editor-left ed)  (editor-move ed window-left))
(define (editor-right ed) (editor-move ed window-right))
(define (editor-up ed)    (editor-move ed window-up))
(define (editor-down ed)  (editor-move ed window-down))
(define (editor-home ed)  (editor-move ed window-home))
(define (editor-end ed)   (editor-move ed window-end))
(define (editor-goto ed p) (editor-move ed (lambda (w) (window-set-point w p))))
(define (editor-scroll ed delta)
  (define fv (editor-focused-view ed))
  (editor-leader-window ed (view-id fv) (window-scroll-visual (view-window fv) delta)))

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
  (define-values (u1 _u3) (editor-undo e3))
  (check-equal? (editor-buffer->string u1 0) "")
  (check-equal? (editor-point u1) (point 0 0))
  (define-values (r1b _u4) (editor-redo u1))
  (check-equal? (editor-buffer->string r1b 0) "abc")

  ;; 多 buffer：各自独立文本 / 账本
  (define ed (editor-open "AAA"))
  (define-values (ed2 bid1) (editor-open-buffer ed "b.txt" "BBB"))
  (check-equal? (editor-focused-buffer-id ed2) bid1)
  (define-values (ed3 _u5) (editor-edit ed2 (edit-insert "x")))
  (check-equal? (editor-buffer->string ed3 bid1) "xBBB")
  (check-equal? (editor-buffer->string ed3 0) "AAA")
  (check-true (editor-can-undo? ed3 bid1))
  (check-false (editor-can-undo? ed3 0))

  ;; 多视图同 buffer：free 映射、follow 镜像
  (define m0 (editor-open "l0\nl1\nl2\nl3\nl4\nl5\nl6"))
  (define-values (m1 v0) (editor-add-view m0 0 3 10))         ; v0 被 focus
  (define m2 (editor-focus-view (editor-set-view-sync m1 v0 'follow) 0))
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

  (displayln "command.rkt: all tests passed"))
