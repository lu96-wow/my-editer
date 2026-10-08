#lang racket

;; 与 core/view/patch.rkt 对应的外部测试（格级 diff / 覆盖输出，clear 并入 render）。
(require rackunit
         "../../core-rebuild/view/patch.rkt"
         "../../core-rebuild/view/base/screen.rkt")

(define (mk rows [cursors '()] [regions '()])
  (screen 6 (length rows) (list->vector rows) cursors regions))

(define s1 (mk (list (list (run 0 "abc" #f)) (list (run 0 "def" #f)))))

;; ---------- 相同帧 → 空差量 ----------
(define-values (r0 v0) (screen-patch s1 s1))
(check-equal? r0 '()) (check-equal? v0 '())

;; ---------- 只重画变化的格（不是整行） ----------
(define s2 (mk (list (list (run 0 "abc" #f)) (list (run 0 "dXf" #f)))))
(define-values (r1 v1) (screen-patch s1 s2))
(check-equal? r1 (list (piece 1 1 "X" #f)))        ; 只第 1 行第 1 列
(check-equal? v1 '())

;; ---------- 光标移动 → 只覆盖那个格（进 selection） ----------
(define s3 (screen 6 2 (vector (list (run 0 "abc" #f)) (list (run 0 "def" #f)))
                   (list (cursor 0 1 #t)) '()))
(define-values (r2 v2) (screen-patch s1 s3))
(check-equal? r2 '())
(check-equal? v2 (list (piece 0 1 "b" (cons 'cursor #f))))

;; ---------- 选区：只发新覆盖的格 ----------
(define s4 (screen 6 2 (vector (list (run 0 "abc" #f)) (list (run 0 "def" #f)))
                   '() (list (region 0 0 2 #t))))
(define-values (r3 v3) (screen-patch s1 s4))
(check-equal? r3 '())
(check-equal? v3 (list (piece 0 0 "ab" (cons 'selection #f))))

;; ---------- 删除：多余旧内容 → 用空格段覆盖（并入 render） ----------
(define del-old (mk (list (list (run 0 "abcd" #f)))))
(define del-new (mk (list (list (run 0 "ab" #f)))))
(define-values (rd vd) (screen-patch del-old del-new))
(check-equal? rd (list (piece 0 2 "  " #f)))        ; 空格覆盖 c/d
(check-equal? vd '())

;; ---------- face 变 → 覆盖该格 ----------
(define hl-old (mk (list (list (run 0 "ab" #f)))))
(define hl-new (mk (list (list (run 0 "a" #f) (run 1 "b" 'kw)))))
(define-values (rh vh) (screen-patch hl-old hl-new))
(check-equal? rh (list (piece 0 1 "b" 'kw)))

;; ---------- 选区消失 → 用文本覆盖回来 ----------
(define sel-old (screen 6 1 (vector (list (run 0 "abc" #f))) '() (list (region 0 0 2 #f))))
(define sel-new (screen 6 1 (vector (list (run 0 "abc" #f))) '() '()))
(define-values (rs vs) (screen-patch sel-old sel-new))
(check-equal? rs (list (piece 0 0 "ab" #f)))
(check-equal? vs '())

;; ---------- 首帧（old = #f）：只发内容 ----------
(define-values (rf vf) (screen-patch #f s1))
(check-equal? rf (list (piece 0 0 "abc" #f) (piece 1 0 "def" #f)))
(check-equal? vf '())

;; ---------- 尺寸变 → 全量内容 ----------
(define s5 (screen 4 2 (vector (list (run 0 "ab" #f)) (list (run 0 "cd" #f))) '() '()))
(define-values (rx vx) (screen-patch s1 s5))
(check-equal? rx (list (piece 0 0 "ab" #f) (piece 1 0 "cd" #f)))

;; ---------- 宽字符：右半格随其字符 ----------
(define sw (screen 10 1 (vector (list (run 0 "中abc" #f))) '() (list (region 0 2 4 #t))))
(define-values (rw vw) (screen-patch #f sw))
(check-equal? rw (list (piece 0 0 "中" #f) (piece 0 4 "c" #f)))
(check-equal? vw (list (piece 0 2 "ab" (cons 'selection #f))))

;; ---------- 高亮 + 选区同格：selection piece 带上 face（不丢外观） ----------
(define fs-old (mk (list (list (run 0 "ab" #f)))))
(define fs-new (screen 6 1 (vector (list (run 0 "a" #f) (run 1 "b" 'kw))) '() (list (region 0 1 2 #f))))
(define-values (rfs vfs) (screen-patch fs-old fs-new))
(check-equal? rfs '())
(check-equal? vfs (list (piece 0 1 "b" (cons 'selection 'kw))))

(displayln "patch.rkt: all tests passed")
