#lang racket

(require "../atom/point.rkt" "../atom/width.rkt"
         "../doc/buffer.rkt" "../doc/document.rkt"
         "window.rkt" "layout.rkt" rackunit)

;;; viewport/mirror.rkt —— 视口映射：把一个 窗口 的可见范围投到另一个 窗口
;;;
;;; 与 重基准 的区别：重基准 是「编辑 → 窗口」（按 编辑-描述 重定位，同一坐标空间）；
;;; 本层是「窗口 → 窗口」（两个 文档 之间的视口同步），**不吃 编辑-描述**。
;;;
;;; 两层，第一层与 模式 无关（统一文本逻辑坐标），第二层才分 裁剪/折行：
;;;
;;;   ① 镜像-位置  —— 逻辑映射（行/列），不换 文档、不看 模式：
;;;       行：**固定行号**，超出目标行数 → 夹到最近
;;;       列：按该行字符长**比例**
;;;   ② 镜像-窗口 —— 取源窗口左上角的逻辑点，按目标窗口的 模式 投影成视口：
;;;       裁剪：顶行 = 行；左列 = 该列的显示列（吸附字符起点）
;;;       折行：顶行 = 行；顶段 = 该列所在的折行段
;;;       最后 窗口-夹紧-视口 夹回合法域（行不够→顶到最近）
;;;
;;; 参数一律「源在前、目标在后」：镜像-位置 返回目标点，镜像-窗口 返回目标窗口
;;; （目标窗口的 文档 / 选区原样保留，只改视口）。
;;;
;;; 纯几何：只依赖 窗口/缓冲/宽度，不改 文档。

(provide 镜像-位置 镜像-窗口)

;;; ---------- ① 逻辑映射（模式 无关） ----------

;; 把源 文档 的点 p 投到目标 文档（逻辑坐标）。
;; 行固定行号（不够夹到最近）；列按行字符长比例；空行/单行都夹到最近。
(define (镜像-位置 d-来源 p d-目标)
  (define n-来源 (文档-行-数量 d-来源))
  (define n-目标 (文档-行-数量 d-目标))
  (define l-来源 (max 0 (min (位置-行 p) (sub1 n-来源))))
  (define l-目标 (min l-来源 (sub1 n-目标)))                    ; 固定行号，越界夹最近
  (define 长度-来源 (文档-行-长度 d-来源 l-来源))
  (define 长度-目标 (文档-行-长度 d-目标 l-目标))
  (define c (max 0 (min (位置-列 p) 长度-来源)))
  (位置 l-目标 (if (zero? 长度-来源) 0 (round (* c (/ 长度-目标 长度-来源))))))   ; 列按比例

;;; ---------- ② 逻辑 → 视口（模式 相关） ----------

;; 窗口可视区左上角对应的逻辑点 (行, 列)（列 是字符索引）。越界行先夹到合法域。
(define (窗口-左上-位置 w)
  (define d (窗口-文档 w))
  (define 行 (max 0 (min (窗口-顶行 w) (sub1 (文档-行-数量 d)))))
  (define 文本 (缓冲-行-引用 (文档-缓冲 d) 行))
  (define 列
    (case (窗口-模式 w)
      [(裁剪) (窗口-左列 w)]
      [(折行) (define 段集 (折行-段列表 文本 (窗口-内容-宽度 w)))
              (car (list-ref 段集 (max 0 (min (窗口-顶段 w) (sub1 (length 段集))))))]
      [else (error '窗口-左上-位置 "未知 mode: ~a" (窗口-模式 w))]))
  (位置 行 (显示列->索引 文本 列)))

;; 某显示列落在第几个折行段（不在任何段内 → 末段）。
(define (段-的-列 文本 宽度 列)
  (define 段集 (折行-段列表 文本 宽度))
  (or (for/first ([s (in-list 段集)] [i (in-naturals)]
                  #:when (and (<= (car s) 列) (< 列 (cdr s)))) i)
      (sub1 (length 段集))))

;; 按目标窗口的 模式 把它定位到逻辑点 (行, 列)。
(define (设置-视口 w 行 列)
  (define w1 (窗口-设置-顶行 w 行))
  (define 文本 (缓冲-行-引用 (窗口-缓冲 w1) 行))
  (define dc (索引->显示列 文本 列))
  (case (窗口-模式 w1)
    [(裁剪) (窗口-夹紧-视口 (窗口-设置-左列 w1 dc))]
    [(折行) (窗口-夹紧-视口 (窗口-设置-顶段 w1 (段-的-列 文本 (窗口-内容-宽度 w1) dc)))]
    [else (error '设置-视口 "未知 mode: ~a" (窗口-模式 w1))]))

;; 把源窗口的可视范围投到目标窗口：源左上角逻辑点 → 目标逻辑点 → 目标视口。
;; **不动目标窗口的 文档**（跨文档各看各的文本），也**不动它的选区**。
(define (镜像-窗口 w-来源 w-目标)
  (define d-来源 (窗口-文档 w-来源))
  (define d-目标 (窗口-文档 w-目标))
  (cond
    [(and (eq? (窗口-模式 w-来源) '裁剪) (eq? (窗口-模式 w-目标) '裁剪))
     ;; 裁剪↔裁剪：横向是**显示列**偏移（作用于整个视口，与具体行无关）。
     ;; 不能经 窗口-左上-位置 —— 它把 左列 经**顶行**文字折成 字符 索引，
     ;; 顶行比 左列 短（如空行）时会被夹到行尾，目标视口就不跟着横向滚了。
     ;; 按顶行**显示宽**比例映射；两边都空行时保持原值（恒等）。
     (define 行-来源 (max 0 (min (窗口-顶行 w-来源) (sub1 (文档-行-数量 d-来源)))))
     (define 行-目标 (min 行-来源 (sub1 (文档-行-数量 d-目标))))
     (define ws (字符串-显示-宽度 (缓冲-行-引用 (文档-缓冲 d-来源) 行-来源)))
     (define wd (字符串-显示-宽度 (缓冲-行-引用 (文档-缓冲 d-目标) 行-目标)))
     (define ls (窗口-左列 w-来源))
     (define ld (cond [(zero? ws) (if (zero? wd) ls 0)]
                      [else (max 0 (round (* ls (/ wd ws))))]))
     (窗口-夹紧-视口
      (窗口-设置-左列 (窗口-设置-顶行 w-目标 行-目标) ld))]
    [else
     (define p (镜像-位置 d-来源 (窗口-左上-位置 w-来源) d-目标))
     (设置-视口 w-目标 (位置-行 p) (位置-列 p))]))

;;; ---------- 测试 ----------

(module+ test
  (define (P l c) (位置 l c))
  (define (win s [h 3] [w 20] [顶部 0] [左 0])
    (窗口-设置-左列 (窗口-设置-顶行 (窗口-打开 (文档-打开 s) h w) 顶部) 左))

  ;; ① 同 文档 → 恒等（行、列都还原）
  (define d0 (文档-打开 "hello\nworld\nfoo"))
  (check-equal? (镜像-位置 d0 (P 1 3) d0) (P 1 3))
  (check-equal? (镜像-位置 d0 (P 2 0) d0) (P 2 0))

  ;; ① 行：固定行号，目标更短 → 夹最近
  (define dA (文档-打开 "l0\nl1\nl2\nl3\nl4"))
  (define dB (文档-打开 "m0\nm1"))
  (check-equal? (镜像-位置 dA (P 0 0) dB) (P 0 0))
  (check-equal? (镜像-位置 dA (P 1 0) dB) (P 1 0))
  (check-equal? (镜像-位置 dA (P 4 0) dB) (P 1 0))    ; 4 → 最近末行 1

  ;; ① 列：按行字符长比例
  (define sA (文档-打开 "abcd\nab\nabcdefgh"))
  (define sB (文档-打开 "ab\nabcdefgh"))
  (check-equal? (镜像-位置 sA (P 0 0) sB) (P 0 0))
  (check-equal? (镜像-位置 sA (P 0 4) sB) (P 0 2))     ; 4/4 * 2 = 2
  (check-equal? (镜像-位置 sA (P 0 2) sB) (P 0 1))     ; 2/4 * 2 = 1
  (check-equal? (镜像-位置 sA (P 2 8) sB) (P 1 8))     ; 8/8 * 8 = 8

  ;; ① 空行 / 单行
  (check-equal? (镜像-位置 (文档-打开 "abc\n") (P 1 0) (文档-打开 "xy\nzw")) (P 1 0))   ; 源空行→列 0
  (check-equal? (镜像-位置 (文档-打开 "abc") (P 0 3) (文档-打开 "xy")) (P 0 2))
  (check-equal? (镜像-位置 (文档-打开 "abc") (P 0 3) (文档-打开 "abcdef")) (P 0 6))

  ;; ① 越界输入 → 先夹
  (check-equal? (镜像-位置 sA (P 99 99) sB) (P 1 8))

  ;; ② 同 文档：视口恒等（顶行 / 左列 保留）
  (define w-相同 (镜像-窗口 (win "hello\nworld\nfoo" 2 20 1 0) (win "hello\nworld\nfoo" 2 20 1 0)))
  (check-equal? (窗口-顶行 w-相同) 1)
  (check-equal? (窗口-左列 w-相同) 0)

  ;; ② 跨 文档：源顶行 4，目标 4 行、高 2 → 夹到末页（最大-顶部 = 2）
  (define wf (镜像-窗口 (win "l0\nl1\nl2\nl3\nl4" 2 20 4 0) (win "m0\nm1\nm2\nm3" 2 20)))
  (check-equal? (窗口-顶行 wf) 2)
  (check-equal? (缓冲->字符串 (窗口-缓冲 wf)) "m0\nm1\nm2\nm3")   ; 目标 文档 未变

  ;; ② 列按比例：源第 0 行 4 宽、左列=4 → 目标第 0 行 2 宽、左列=2
  (define wf2 (镜像-窗口 (win "abcd\nab\nabcdefgh" 2 20 0 4) (win "ab\nabcdefgh" 2 20 0 0)))
  (check-equal? (窗口-顶行 wf2) 0)
  (check-equal? (窗口-左列 wf2) 2)

  ;; ② 顶行比 左列 短 / 为空时，横向仍必须跟随。
  ;; 回归：旧实现经 窗口-左上-位置 把 左列 折成顶行的 字符 索引，
  ;; 被夹到顶行行尾 → 目标视口不再横向滚。
  (define wshort (镜像-窗口 (win "abc\nabcdefghij" 1 4 0 5)
                                (win "abc\nabcdefghij" 1 4 0 0)))
  (check-equal? (窗口-左列 wshort) 5)
  (define wempty (镜像-窗口 (win "\nabcdefghij" 2 4 0 6)
                                (win "\nabcdefghij" 2 4 0 0)))
  (check-equal? (窗口-左列 wempty) 6)                 ; 两边顶行都空 → 保持原值
  (check-equal? (窗口-顶行 wempty) 0)

  ;; ② 折行 投影：裁剪 源 → 折行 目标（列 6 落在第 2 个折行段 4..8）
  (define wa (窗口-设置-左列 (窗口-打开 (文档-打开 "abcdefgh") 2 20) 6))
  (define wb (窗口-设置-模式 (窗口-打开 (文档-打开 "abcdefgh") 2 4) '折行))
  (define mb (镜像-窗口 wa wb))
  (check-equal? (窗口-顶行 mb) 0)
  (check-equal? (窗口-顶段 mb) 1)

  ;; ② 折行 源 → 裁剪 目标（段 1 起点列 4 → 左列 4）
  (define wl (窗口-设置-顶段 (窗口-设置-模式 (窗口-打开 (文档-打开 "abcdefgh") 2 4) '折行) 1))
  (define wc (镜像-窗口 wl (窗口-打开 (文档-打开 "abcdefgh") 2 20)))
  (check-equal? (窗口-顶行 wc) 0)
  (check-equal? (窗口-左列 wc) 4)

  ;; ② 折行 源 → 折行 目标（同文档同宽 → 段号对齐）
  (define wr (镜像-窗口 wl (窗口-设置-模式 (窗口-打开 (文档-打开 "abcdefgh") 2 4) '折行)))
  (check-equal? (窗口-顶段 wr) 1)

  ;; ② 越界 顶行 的源也能投（先夹，不崩）
  (define wover (窗口-设置-顶行 (窗口-打开 (文档-打开 "abcdefgh") 2 20) 99))
  (check-equal? (窗口-顶行 (镜像-窗口 wover (窗口-打开 (文档-打开 "xy") 2 20))) 0)

  (displayln "mirror.rkt: all tests passed"))
