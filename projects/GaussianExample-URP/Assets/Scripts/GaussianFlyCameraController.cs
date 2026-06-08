// SPDX-License-Identifier: MIT

using UnityEngine;

namespace GaussianSplatting.Runtime
{
    public class GaussianFlyCameraController : MonoBehaviour
    {
        [SerializeField] float m_MoveSpeed = 5f;
        [SerializeField] float m_FastMoveSpeed = 15f;
        [SerializeField] float m_RotateSpeed = 2f;

        float m_Pitch;
        float m_Yaw;

        void Start()
        {
            Vector3 euler = transform.eulerAngles;
            m_Yaw = euler.y;
            m_Pitch = euler.x;
        }

        void Update()
        {
            if (Input.GetMouseButton(1))
            {
                m_Yaw += Input.GetAxis("Mouse X") * m_RotateSpeed;
                m_Pitch -= Input.GetAxis("Mouse Y") * m_RotateSpeed;
                m_Pitch = Mathf.Clamp(m_Pitch, -89f, 89f);
                transform.rotation = Quaternion.Euler(m_Pitch, m_Yaw, 0f);

                bool fast = Input.GetKey(KeyCode.LeftShift);
                float speed = fast ? m_FastMoveSpeed : m_MoveSpeed;
                Vector3 move = Vector3.zero;

                if (Input.GetKey(KeyCode.W)) move += transform.forward;
                if (Input.GetKey(KeyCode.S)) move -= transform.forward;
                if (Input.GetKey(KeyCode.D)) move += transform.right;
                if (Input.GetKey(KeyCode.A)) move -= transform.right;

                transform.position += move.normalized * speed * Time.deltaTime;
            }
        }
    }
}
