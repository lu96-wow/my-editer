#lang racket

(require "../../../core/text/base/line.rkt"
         "../../base/face.rkt"
         "api.rkt"
         "lex.rkt")

;;; lab-rebuild/plugin/words.rkt —— 词着色（内置插件）
;;;
;;; 颜色来自一张**持久表** word → 色号，而不是整词 hash：
;;;   · 首次见到某个词 → 取“下一个号”（= 表里已有词数），插进表；
;;;   · 以后每次见到 → 用表里的号。
;;; 于是：同词同色；不同词拿不同的号（模色板才可能撞，相邻词不会）；表只增不减，
;;; 所以**在词前面插入新词也不会让后面的词变色**（比 hash 更稳，也不靠碰撞运气）。
;;;
;;; 输入不闪：边打字边加长时整词一直在变，任何 f(整词) 都不稳定 —— 学编辑器插件
;;; （LSP 语义高亮）：`change` 用编辑位置找出**活动词**（光标所在词），本次跳过它（先不上色、
;;; 也不占号）；其余词照常用表上色。敲下分隔符 / 移开后活动词“定下来”，下一次才上色。
;;;
;;; 状态 = 这张表（hash word -> color-index）。`open` 从零建表；`change` 在旧表上增量补。

(provide word-plugin)

;;; ---------- 一张表 → 本趟 fills ----------

;; tokens 按出现顺序；skip = #f | (list line start end)（活动词，本次跳过）。
;; map = 旧表。→ (values 新表 fills)
(define (assign-fills tokens skip map)
  (define out (make-hash))
  (define next (box (hash-count map)))
  (define fills
    (for/list ([tok (in-list tokens)]
               #:unless (and skip (= (car tok) (car skip)) (= (cadr tok) (cadr skip))))
      (match-define (list ln s e w) tok)
      (define idx
        (cond [(hash-ref map w #f)]          ; 见过 → 沿用（0 也是真值）
              [(hash-ref out w #f)]          ; 本趟里前面出现过
              [else (begin0 (unbox next) (set-box! next (add1 (unbox next))))]))
      (hash-set! out w idx)
      (list ln s ln e (palette-color 'word idx))))
  (define new-map (hash-copy map))
  (for ([(w i) (in-hash out)]) (hash-set! new-map w i))
  (values new-map fills))

;;; ---------- 活动词（光标所在词） ----------
;; 在 lex.rkt 里（词着色 / 关键字插件共用）。

(define (word-open text _path)
  (assign-fills (scan-words text) #f (hash)))

(define (word-change state edits lines _path)
  (assign-fills (scan-words (lines->string (vector->list lines)))
                (active-token lines edits)
                (or state (hash))))

(define word-plugin
  (plugin 'words word-open word-change))
