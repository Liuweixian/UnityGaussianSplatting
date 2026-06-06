using System;
using UnityEngine;

public class RotatingObject : MonoBehaviour
{
    public float rotating_speed = 1f;
    private void Awake()
    {
        Application.targetFrameRate = 60;
    }

    // Update is called once per frame
    void Update()
    {
        this.transform.Rotate(Vector3.up, rotating_speed,Space.Self);
    }
}
