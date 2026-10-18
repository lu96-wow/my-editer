;; lab.rkt —— 高亮 / 补全 / 文档 演示
;;
;; 输入至少 2 个词字符  自动弹出补全（↑↓ 选，Enter 接受，Esc 取消）
;; C-c h  看光标前词的文档（下方固定高度面板）

(define (square x)
  (* x x))

(define (sum-of-squares a b)
  (+ (square a) (square b)))

(define (main)
  (let ([xs (list 1 2 3 4 5)])
    (map square xs)))