#lang racket

(require "../atom/point.rkt" "../atom/edit.rkt" "../atom/selection.rkt" "../atom/attr.rkt"
         "../doc/buffer.rkt" "../doc/document.rkt"
         "../viewport/window.rkt" "../viewport/layout.rkt"
         "../unit/history.rkt"
         "state.rkt" "write.rkt" "neutral.rkt" "program.rkt" "reaction.rkt" rackunit)

;;; platform/command.rkt —— 用户命令：leader + ensure + 账本
;;;
;;; 编辑原语是 program.rkt 的 editor-command；这里只固定「用户编辑」的策略：
;;;   editor-view-edit / editor-edit = editor-command + #:reaction 'leader + #:record? 'default
;;; 导航与同步是 editor-view-put-window（裸写）+ window-* + editor-view-follow 的组合。
;;; 所有原语按 vid 定位；focus 只是解析 vid 的糖。

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
 editor-view-follow
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
 editor-scroll
 editor-follow)

;; 解析焦点 vid —— 用户面唯一读 focus 的地方。
(define (focused-vid ed) (view-id (editor-focused-view ed)))

;;; ---------- 编辑（指定 view，leader 语义） ----------
;; 薄封装：策略全在 editor-command 的参数里；这里只固定「用户编辑」的取值。

(define (editor-view-edit ed vid op)
  (editor-command ed op #:view vid #:reaction 'leader #:record? 'default))

;;; ---------- 撤销 / 重做（指定 view 所属 document 的账本） ----------

;; 依次施加一串 change（撤销/重放）；每个 change 后把 vid 的视图 leader 到插入后。
;; 返回 (values editor 生效文本descs 生效属性descs)。
(define (apply-change-seq ed did vid chs)
  (for/fold ([e ed] [texts '()] [attrs '()]) ([ch (in-list chs)])
    (define-values (e1 res) (editor-apply-change e did ch #f))   ; trusted
    (cond
      [(not res) (values e1 texts attrs)]
      [else
       (define tds (change-result-applied-texts res))
       (define ads (change-result-applied-attrs res))
       (define e2 (if (null? tds) e1 (editor-leader-view e1 vid (editor-document e1 did) tds)))
       (values e2 (append texts tds) (append attrs ads))])))

(define (editor-view-undo ed vid)
  (define did (editor-view-document-id ed vid))
  (define-values (st h*) (history-pop-undo (editor-history ed did)))
  (cond
    [(not st) (values ed #f)]
    [else
     (define-values (ed* texts attrs) (apply-change-seq ed did vid (step-undo st)))
     ;; 撤销后 leader 光标回到该步开始前，并 ensure
     (define w* (window-ensure-point
                 (window-set-point (view-window (editor-view-ref ed* vid)) (step-pre-point st))))
     (define ed** (editor-leader-window ed* vid w*))
     (values (editor-put-history ed** did h*) (change-report texts attrs))]))

(define (editor-view-redo ed vid)
  (define did (editor-view-document-id ed vid))
  (define-values (st h*) (history-pop-redo (editor-history ed did)))
  (cond
    [(not st) (values ed #f)]
    [else
     (define-values (ed* texts attrs) (apply-change-seq ed did vid (step-replay st)))
     (values (editor-put-history ed* did h*) (change-report texts attrs))]))

;;; ---------- 导航（指定 view；移动后 ensure + follow 镜像） ----------
;; 裸写用 editor-view-put-window（program.rkt），同步用 editor-view-follow；
;; 这里的 editor-view-move 是二者的组合，故不对外。

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
                        (window-scroll (view-window (editor-view-ref ed vid)) delta)))

;;; ---------- 同步（显式、可组合） ----------
;; 把同 document 的 follow view 镜像到 vid 的当前 window；vid 自身不动。
;; 与裸写组合：先 editor-view-put-window，再 editor-view-follow。

(define (editor-view-follow ed vid)
  (editor-leader-window ed vid (view-window (editor-view-ref ed vid))))
(define (editor-follow ed) (editor-view-follow ed (focused-vid ed)))

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
  (check-equal? (change-report-texts r-u3)
                (list (edit-desc (point 0 2) (point 0 3) "")
                      (edit-desc (point 0 1) (point 0 2) "")
                      (edit-desc (point 0 0) (point 0 1) "")))
  (define-values (r1b r-u4) (editor-redo u1))
  (check-equal? (editor-buffer->string r1b 0) "abc")
  (check-equal? (change-report-texts r-u4)
                (list (edit-desc (point 0 0) (point 0 0) "a")
                      (edit-desc (point 0 1) (point 0 1) "b")
                      (edit-desc (point 0 2) (point 0 2) "c")))

  ;; 多 document：各自独立文本 / 账本
  (define ed (editor-open "AAA"))
  (define-values (ed2 bid1) (editor-open-document ed "BBB" #:name "b.txt" #:focus? #t))
  (check-equal? (editor-document-id ed2) bid1)
  (define-values (ed3 _u5) (editor-edit ed2 (edit-insert "x")))
  (check-equal? (editor-buffer->string ed3 bid1) "xBBB")
  (check-equal? (editor-buffer->string ed3 0) "AAA")
  (check-true (editor-can-undo? ed3 bid1))
  (check-false (editor-can-undo? ed3 0))

  ;; 多视图同 document：free 映射、follow 镜像
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
  (define-values (g3 other) (editor-open-document g2 "OTHER" #:name "other"))
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

  ;; 编辑原语 editor-command：策略是参数
  (define ec0 (editor-open "abcdef"))
  ;;   默认：焦点 view 的选区 + reaction 'none；#:record? 'default → 跟随 document 策略（这里 #:history? #t）
  (define-values (ec1 _ec-r1) (editor-command ec0 (edit-insert "X")))
  (check-equal? (editor-buffer->string ec1 0) "Xabcdef")
  (check-equal? (editor-point ec1) (point 0 0))          ; none：光标不动
  (check-true (editor-can-undo? ec1))                    ; 默认跟随 document
  ;;   #:record? #f：显式不记账
  (define-values (ec1n _ec1nr) (editor-command ec0 (edit-insert "X") #:record? #f))
  (check-false (editor-can-undo? ec1n))
  ;;   显式 #:selection：程序化定位
  (define-values (ec2 _ec-r2) (editor-command ec0 (edit-insert "Y")
                                           #:selection (list (caret (point 0 3)))))
  (check-equal? (editor-buffer->string ec2 0) "abcYdef")
  ;;   显式 #:reaction 'leader + #:record?：用户编辑语义
  (define-values (ec3 _ec-r3) (editor-command ec0 (edit-insert "X") #:reaction 'leader #:record? #t))
  (check-equal? (editor-point ec3) (point 0 1))          ; leader：光标推进到插入后
  (check-true (editor-can-undo? ec3))
  ;;   显式 #:trusted? #t：绕 read-only
  (define-values (ecr _ecr-r) (editor-put-attr (editor-open "abc") 0 (point 0 0) (point 0 3) read-only-key #t))
  (define-values (ecr1 rcr1) (editor-command ecr (edit-insert-char #\X)
                                             #:selection (list (caret (point 0 1)))))
  (check-false rcr1)
  (check-equal? (editor-buffer->string ecr1 0) "abc")
  (define-values (ecr2 _ec-rcr2) (editor-command ecr (edit-insert-char #\X)
                                              #:selection (list (caret (point 0 1))) #:trusted? #t))
  (check-equal? (editor-buffer->string ecr2 0) "aXbc")

  ;; 显式同步：裸写不同步；editor-follow 才把 follow view 镜像到 leader 的 window
  ;; （leader 须光标可见：rebase-follow 会按 mirror 后的光标重新 ensure）
  (define f0 (editor-open "l0\nl1\nl2\nl3\nl4\nl5" 3 10))
  (define-values (f1 fv) (editor-add-view f0 0 3 10 #:sync 'follow))
  (define f2 (editor-focus-view f1 0))
  (define w* (window-set-top-line (window-set-point (editor-window f2) (point 5 0)) 3))
  (define f3 (editor-put-window f2 w*))
  (check-equal? (editor-view-top-line f3 fv) 0)                  ; 裸写不同步
  (check-equal? (editor-view-top-line (editor-follow f3) fv) 3)  ; follow 后镜像

  ;; 文本 + 属性一条命令、一步撤销：撤销要把属性一起正确地回退
  (define ba0 (editor-open "abc"))
  (define-values (ba1 _ba-r)
    (editor-command ba0 (edit-insert "X")
                    #:selection (list (caret (point 0 1)))
                    #:attrs (lambda (_ed _bid texts)
                              (for/list ([d (in-list texts)])
                                (attr-set (edit-desc-start d) (edit-desc-after-position d)
                                          read-only-key #t)))
                    #:reaction 'leader #:record? #t))
  (check-equal? (editor-buffer->string ba1 0) "aXbc")
  (check-equal? (editor-attr-key-runs ba1 0 0 read-only-key) (list (list 1 2 #t)))
  (check-equal? (editor-undo-depth ba1 0) 1)
  (define-values (ba2 _ba-u) (editor-undo ba1))
  (check-equal? (editor-buffer->string ba2 0) "abc")
  (check-false (attr-read-only? (editor-attr-at ba2 0 (point 0 1))))
  ;; 重做也要把文本 + 属性恢复
  (define-values (ba3 _ba-r2) (editor-redo ba2))
  (check-equal? (editor-buffer->string ba3 0) "aXbc")
  (check-equal? (editor-attr-key-runs ba3 0 0 read-only-key) (list (list 1 2 #t)))

  ;; 删除带属性的文本再撤销：属性不得丢失（旧实现的回归点）
  (define br0 (editor-open "abc"))
  (define-values (br1 _br-r) (editor-apply-attrs br0 0 (list (attr-set (point 0 0) (point 0 3) read-only-key #t))))
  (define br2 (editor-set-selections br1 (list (selection (point 0 1) (point 0 2)))))
  (define-values (br3 _br-e) (editor-command br2 (edit-backspace) #:trusted? #t #:reaction 'leader #:record? #t))
  (check-equal? (editor-buffer->string br3 0) "ac")
  (define-values (br4 _br-u) (editor-undo br3))
  (check-equal? (editor-buffer->string br4 0) "abc")
  (check-equal? (editor-attr-key-runs br4 0 0 read-only-key) (list (list 0 3 #t)))

  ;; 跨 document 视口同步（行数相同 → 行恒等）
  (define lk0 (editor-open (string-join (for/list ([i (in-range 8)]) (format "l~a" i)) "\n") 3 10 #:name "A"))
  (define-values (lk1 vidB) (editor-open-document
                             lk0 (string-join (for/list ([i (in-range 8)]) (format "m~a" i)) "\n")
                             3 10 #:name "B" #:focus? #f))
  (check-false (editor-view-link lk1 0))
  (define lk2 (editor-link-views lk1 'pair (list 0 vidB)))
  (check-equal? (editor-view-link lk2 0) 'pair)
  (check-equal? (editor-view-link lk2 vidB) 'pair)
  (check-equal? (editor-links lk2) '(pair))
  (define lk3 (editor-view-goto lk2 0 (point 5 0)))
  (check-equal? (editor-view-top-line lk3 0) 3)      ; ensure：point 5 → top-line 3
  (check-equal? (editor-view-top-line lk3 vidB) 3)   ; 行固定 → 3
  (define lk4 (editor-view-goto lk3 0 (point 0 0)))
  (check-equal? (editor-view-top-line lk4 vidB) 0)
  ;; 解链后不再跟
  (define lk5 (editor-unlink-view lk4 vidB))
  (check-false (editor-view-link lk5 vidB))
  (define lk6 (editor-view-goto lk5 0 (point 5 0)))
  (check-equal? (editor-view-top-line lk6 vidB) 0)   ; 已解链，不动

  ;; 目标更短 → 行夹到最近
  (define sk0 (editor-open (string-join (for/list ([i (in-range 8)]) (format "l~a" i)) "\n") 3 10 #:name "A"))
  (define-values (sk1 vidS) (editor-open-document sk0 "m0\nm1\nm2\nm3" 3 10 #:name "S" #:focus? #f))
  (define sk2 (editor-link-views sk1 'short (list 0 vidS)))
  (define sk3 (editor-view-goto sk2 0 (point 5 0)))
  (check-equal? (editor-view-top-line sk3 0) 3)
  (check-equal? (editor-view-top-line sk3 vidS) 1)   ; 3 → 最近末页（max-top=1）

  ;; 列按比例：A line0 宽 8、B line0 宽 2；A left-col 4 → B left-col 1（4/8*2）
  (define ck0 (editor-open "abcdefgh\nzzzz" 3 20 #:name "A"))
  (define-values (ck1 vidC) (editor-open-document ck0 "xy\nzzzz" 3 20 #:name "C" #:focus? #f))
  (define ck2 (editor-link-views ck1 'col (list 0 vidC)))
  (define ck3 (editor-view-set-left-col ck2 0 4))
  (define ck4 (editor-view-follow ck3 0))
  (check-equal? (editor-view-left-col ck4 0) 4)
  (check-equal? (editor-view-left-col ck4 vidC) 1)

  ;; wrap follower：leader clip 滚到列 6 → follower（宽 4）的 top-seg = 1
  (define wk0 (editor-open "abcdefgh" 3 20 #:name "A"))
  (define-values (wk1 vidW) (editor-open-document wk0 "abcdefgh" 3 4 #:name "W" #:focus? #f))
  (define wk2 (editor-view-set-mode wk1 vidW 'wrap))
  (define wk3 (editor-link-views wk2 'wr (list 0 vidW)))
  (define wk4 (editor-view-follow (editor-view-set-left-col wk3 0 6) 0))
  (check-equal? (editor-view-top-seg wk4 vidW) 1)

  (displayln "command.rkt: all tests passed"))
