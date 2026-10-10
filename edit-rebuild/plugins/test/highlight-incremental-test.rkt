#lang racket

;;; edit-rebuild/plugins/test/highlight-incremental-test.rkt —— face 插件协议（headless）
;;;
;;;   raco test edit-rebuild/plugins/test/highlight-incremental-test.rkt
;;;
;;; 覆盖：open/change 产出「每行向量」的层；change 只回脏行；层与全量一致；
;;;       行结构变化（增删换行）；「正在输入的词」不上色、下次编辑后上色。

(require rackunit
         "../../core/extension/face-plugin.rkt"
         "../highlight/syntax.rkt"
         "../highlight/words.rkt"
         "../../core/face/face.rkt"
         "../../core/face/line-scan.rkt"
         "../../../core/text/base/track.rkt"
         "../../../core/text/base/line.rkt"
         "../../../core/text/base/change.rkt"
         "../../../core/text/base/range.rkt"
         "../../../core/text/base/point.rkt")

(define (text-track str) (track-of-list (string->lines str)))

(define (replace-change l0 c0 l1 c1 new-len)          ; 单行替换，新长度 new-len
  (change (range-of (point l0 c0) (point l1 c1))
          (range-of (point l0 c0) (point l0 (+ c0 new-len)))))

(define (insert-change line col len)
  (change (range-of (point line col) (point line col))
          (range-of (point line col) (point line (+ col len)))))

(define (ctx old new changes [cursor #f])
  (face-ctx old new changes (dirty-lines (changes->dirty-lines changes))
            "../../edit-rebuild/test/test.rkt" cursor))

(define (line-face layer i) (track-ref layer i))

;;; ---------- syntax：行局部 + 只回脏行 ----------

(define old-s (text-track "let x 1\nfoo y 2"))
(define new-s (text-track "let y 1\nfoo y 2"))
(define-values (ss0 sl0)
  ((face-plugin-open syntax-plugin) old-s "../../edit-rebuild/test/test.rkt"))
(check-not-false (vector-ref (line-face sl0 0) 0))          ; "let" 关键字
(check-false (line-face sl0 1))         ; "foo" 不是

;; 改第 0 行（x -> y，非关键字）：脏行只有 0；第 1 行层与全量一致，且结构共享
(define-values (_ss1 sl1 dirty-s)
  ((face-plugin-change syntax-plugin) ss0 sl0
   (ctx old-s new-s (list (replace-change 0 4 0 5 1)))))
(check-false (dirty-all? dirty-s))
(check-equal? (dirty-ls dirty-s) '(0))
(check-equal? (line-face sl1 1) (line-face sl0 1))     ; 未变行共享
(define-values (_s sx)
  ((face-plugin-open syntax-plugin) new-s "../../edit-rebuild/test/test.rkt"))
(check-equal? (line-face sl1 0) (line-face sx 0))      ; 脏行与全量一致
(check-not-false (vector-ref (line-face sl1 0) 0))          ; "let" 关键字

;;; ---------- syntax：行结构变化（插入 / 删除换行）后层行数必须随文本 ----------

;; 插入换行："let x 1" -> "let\n x 1"（2 行 -> 3 行）
(define new-s2 (text-track "let\n x 1\nfoo y 2"))
(define-values (_ss2 sl2 _d2)
  ((face-plugin-change syntax-plugin) ss0 sl0
   (ctx old-s new-s2
        (list (change (range-of (point 0 3) (point 0 3))
                      (range-of (point 0 3) (point 1 0)))))))
(check-equal? (track-length sl2) (track-length new-s2))
(define-values (_a2 sx2) ((face-plugin-open syntax-plugin) new-s2 "../../edit-rebuild/test/test.rkt"))
(check-equal? (line-face sl2 0) (line-face sx2 0))
(check-equal? (line-face sl2 1) (line-face sx2 1))
(check-equal? (line-face sl2 2) (line-face sx2 2))       ; 未变尾行结构共享后仍对齐

;; 删除换行："let x 1\nfoo y 2" -> "let x 1foo y 2"（2 行 -> 1 行）
(define new-s3 (text-track "let x 1foo y 2"))
(define-values (_ss3 sl3 _d3)
  ((face-plugin-change syntax-plugin) ss0 sl0
   (ctx old-s new-s3
        (list (change (range-of (point 0 7) (point 1 0))
                      (range-of (point 0 7) (point 0 7)))))))
(check-equal? (track-length sl3) (track-length new-s3))
(define-values (_a3 sx3) ((face-plugin-open syntax-plugin) new-s3 "../../edit-rebuild/test/test.rkt"))
(check-equal? (line-face sl3 0) (line-face sx3 0))

;;; ---------- words：输入时不变色 ----------

(define path "../../edit-rebuild/test/test.rkt")
(define old-w (text-track "alpha beta\ngamma delta"))
(define-values (wt0 wl0) ((face-plugin-open word-plugin) old-w path))
(check-false wt0)                                        ; open：无 pending，整篇上色
(check-not-false (vector-ref (line-face wl0 0) 0))       ; alpha 有色
(check-not-false (vector-ref (line-face wl0 0) 6))       ; beta 有色

;; 改第 0 行 "alpha" -> "zzzz"：插入点在 "zzzz" 内 → pending，不上色
(define new-w (text-track "zzzz beta\ngamma delta"))
(define-values (wt1 wl1 dirty-w)
  ((face-plugin-change word-plugin) wt0 wl0
   (ctx old-w new-w (list (replace-change 0 0 0 5 4)))))
(check-equal? wt1 '(0 0 4))                              ; state = 正在输入的词
(check-false (vector-ref (line-face wl1 0) 0))           ; zzzz 不上色
(check-not-false (vector-ref (line-face wl1 0) 5))       ; beta 照常
(check-equal? (line-face wl1 1) (line-face wl0 1))       ; 未变行结构共享
(check-equal? (dirty-ls dirty-w) '(0))

;; 纯光标移动：光标仍在 pending 词里 → 保持不上色
(define-values (wt1a wl1a _d1a)
  ((face-plugin-change word-plugin) wt1 wl1
   (ctx new-w new-w '() (cons 0 2))))
(check-equal? wt1a '(0 0 4))
(check-false (vector-ref (line-face wl1a 0) 0))

;; 纯光标移动：光标离开 pending 词 → 算「编辑完」，旧词上色
(define-values (wt1b wl1b _d1b)
  ((face-plugin-change word-plugin) wt1 wl1
   (ctx new-w new-w '() (cons 1 0))))
(check-false wt1b)                                       ; 结算
(check-not-false (vector-ref (line-face wl1b 0) 0))      ; zzzz 上色

;; 下一次编辑（另一行）：旧的 "zzzz" 重扫→上色；新的正在输入的词不上色
(define new-w2 (text-track "zzzz beta\ngamma x"))
(define-values (wt2 wl2 dirty-w2)
  ((face-plugin-change word-plugin) wt1 wl1
   (ctx new-w new-w2 (list (replace-change 1 6 1 11 1)))))
(check-equal? wt2 '(1 6 7))                              ; 新 pending
(check-not-false (vector-ref (line-face wl2 0) 0))       ; zzzz 已上色
(check-false (vector-ref (line-face wl2 1) 6))           ; x 不上色
(check-not-false (member 0 (dirty-ls dirty-w2)))         ; 旧 pending 行在脏区

;; pending 词连续增长：始终不上色（输入过程中不闪）
(define w-a (text-track "ab"))
(define w-b (text-track "abc"))
(define-values (p-a l-a) ((face-plugin-open word-plugin) (text-track "") path))
(define-values (p1 l1 _wd1) ((face-plugin-change word-plugin) p-a l-a
                            (ctx (text-track "") w-a (list (insert-change 0 0 2)))))
(check-equal? p1 '(0 0 2))
(define-values (p2 l2 _wd2) ((face-plugin-change word-plugin) p1 l1
                            (ctx w-a w-b (list (insert-change 0 2 1)))))
(check-equal? p2 '(0 0 3))
(check-false (line-face l2 0))                           ; 整行只有 pending 词 → 无 face

;; 同词同色，与出现位置无关
(define-values (_p wa) ((face-plugin-open word-plugin) (text-track "alpha") path))
(define-values (_q wb) ((face-plugin-open word-plugin) (text-track "zz alpha") path))
(check-equal? (vector-ref (line-face wa 0) 0)
              (vector-ref (line-face wb 0) 3))
